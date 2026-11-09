/// --- The Kairo Project --------------------------- Memory/ArenaList.k --- ///
///
///   ArenaList: a slab-indexed growable array allocated from an arena.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/KPlacement.hh" // construct_at
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KLog.hh"
ffi "c++" import "cstddef"
ffi "c++" import "utility"
ffi "c++" import "cstring"
ffi "c++" import "memory"

import Memory::ArenaAllocator::ArenaAllocator

/// Initial capacity of an ArenaList's chunk-descriptor table. Module scope
/// rather than a static member: Kairo has no class-level constant.
pub
const ARENA_LIST_DESCRIPTOR_INIT: usize = 8

/// ArenaList<T> arena-backed, slab-indexed dynamic array.
///
/// Design:
///   A growable list where all memory is bump-allocated from an internal
///   ArenaAllocator. Data is stored across fixed-size slabs (chunks),
///   each holding exactly _slab_size entries. This uniform slab size is
///   an invariant it enables O(1) random access via integer division:
///     chunk = idx / _slab_size,  offset = idx % _slab_size
///
/// Why not std::vector:
///   vector must maintain a single contiguous buffer, which means
///   geometric reallocation (copy entire contents on growth). For a
///   compiler processing millions of AST nodes / tokens in a single
///   pass, this is catastrophic each doubling copies all prior data,
///   and peak memory is 3 > live data (old + new + copy overlap).
///   ArenaList never copies, never moves, never reallocates existing
///   data. Growth is always append-only: allocate a new slab from the
///   arena and start filling it. Existing pointers remain valid forever
///   (until destroy). The tradeoff is non-contiguous memory, which
///   means slightly worse linear scan prefetch vs vector but for
///   random access and pointer stability, this wins decisively.
///
/// Chunk descriptor table:
///   A separate arena-allocated array of Chunk structs (base pointer,
///   count, capacity) that maps chunk index -> slab. The table grows
///   by doubling (old table is abandoned in the arena no free needed).
///   This is a few hundred bytes even for huge lists.
///
/// Memory ownership:
///   All memory (slabs + descriptor table) lives in the ArenaAllocator.
///   clear() resets metadata without touching memory O(1), slabs are
///   reused on next push. clear_zero() does a full SIMD-accelerated
///   arena reset for cases where zeroed memory is required. destroy()
///   returns all arena blocks to GlobalRecycler.
///
/// API:
///   push(val)   copy val to end of list
///   slot()      return pointer to uninitialized memory at end, caller
///                 constructs. avoids wasted default-construct of emplace.
///   emplace()   slot() + default construct, returns pointer
///   pop()       remove and return last element
///   get(idx)    O(1) random access by slab division, null if OOB
///   operator[]  bounds-checked get, crashes on OOB
///   front/back  pointer to first/last element
///   op in       yield-based iteration across all chunks
///
/// Thread safety:
///   None. Single-owner. One ArenaList per thread or per pass.
///   The underlying ArenaAllocator's GlobalRecycler interaction is
///   the only cross-thread touchpoint, and that's lock-free.
///
/// Complexity:
///   push/slot/emplace O(1) amortized (slab alloc on exhaustion)
///   pop               O(1)
///   get/operator[]    O(1)
///   front/back/size   O(1)
///   clear             O(1)
///   clear_zero        O(arena bytes touched)
///   destroy           O(arena blocks)
///   op in             O(n)
///
pub class <T> ArenaList {
    struct Chunk {
        var base:     unsafe *T
        var count:    usize
        var capacity: usize
    }

    priv var _owned_arena: ArenaAllocator                 ///< only used when arena is internal
    priv var _arena:       unsafe *ArenaAllocator = &null ///< non-null = external (not owned)
    priv var _chunks:      unsafe *Self::Chunk    = &null
    priv var _chunk_count: usize                  = 0
    priv var _total:       usize                  = 0
    priv var _chunk_cap:   usize                  = 0
    priv var _slab_size:   usize                  = 0

    ///
    /// \brief Default constructor owns its own internal ArenaAllocator.
    /// Use for temporary lists during parsing that don't need to share memory.
    ///
    pub fn ArenaList(self) {
        var slab_size: usize = 256
        self._slab_size = if slab_size > 0 => slab_size else => 256

        var padding = 2 * (alignof(cxx::std::max_align_t) - 1)
        var arena_sz = self._slab_size * sizeof(T) + ARENA_LIST_DESCRIPTOR_INIT * sizeof(Self::Chunk) + padding

        // Lazily: the first push makes the block. Every AST node's annotation
        // list is built here and then handed the context's arena by
        // init_annotations (set_allocator), so an eager block -- and the debug
        // line formatted for it whatever the log level -- was a malloc, a free
        // and an f-string per node: ~7.5M of each on the self-host graph.
        self._owned_arena.init_lazy(arena_sz)
        self._arena = unsafe &self._owned_arena
    }

    fn ArenaList(self, slab_size: usize) {
        self._slab_size = if slab_size > 0 => slab_size else => 256

        var padding = 2 * (alignof(cxx::std::max_align_t) - 1)
        var arena_sz = self._slab_size * sizeof(T) + ARENA_LIST_DESCRIPTOR_INIT * sizeof(Self::Chunk) + padding

        // Lazily: the first push makes the block. Every AST node's annotation
        // list is built here and then handed the context's arena by
        // init_annotations (set_allocator), so an eager block -- and the debug
        // line formatted for it whatever the log level -- was a malloc, a free
        // and an f-string per node: ~7.5M of each on the self-host graph.
        self._owned_arena.init_lazy(arena_sz)
        self._arena = unsafe &self._owned_arena
    }

    ///
    /// \brief External-arena constructor does NOT own the arena.
    ///
    /// The caller guarantees the arena outlives this list.
    /// destroy() will NOT tear down the arena.
    /// Use when the list's contents need to outlive the list itself
    /// (e.g. AST node child arrays that live in the node arena).
    ///
    fn ArenaList(self, arena: unsafe *ArenaAllocator, slab_size: usize = 256) {
        self._slab_size = if slab_size > 0 => slab_size else => 256
        self._arena     = arena                                     ///< external not owned
    }

    pub fn set_allocator(self, arena: unsafe *ArenaAllocator, slab_size: usize = 256) {
        if self._total > 0 {
            kairo::std::ice_fail(
                "ArenaList::set_allocator: cannot switch allocator on non-empty list",
            )
        }

        if self._arena == unsafe &self._owned_arena {
            self._owned_arena.destroy()
        }

        self._chunks      = &null
        self._chunk_count = 0
        self._chunk_cap   = 0
        self._total       = 0
        self._slab_size   = if slab_size > 0 => slab_size else => 256
        self._arena       = arena
        // no allocation of descriptor table or slab here
    }

    pub fn has_allocator(const self) -> bool {
        return self._arena != &null
    }

    pub fn push(self, val: T) -> unsafe *T {
        self.ensure_space()
        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        var        dst    = unsafe &chunk->base[chunk->count]
        kairo::construct_at<T>(unsafe (dst as unsafe *void), cxx::std::move(val))
        chunk->count += 1
        self._total += 1
        return unsafe &chunk->base[chunk->count - 1]
    }

    pub fn slot(self) -> unsafe *T {
        self.ensure_space()
        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        var        ptr    = unsafe &chunk->base[chunk->count]
        chunk->count += 1
        self._total += 1
        return ptr
    }

    fn emplace(self) -> unsafe *T {
        self.ensure_space()
        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        var        slot   = unsafe &chunk->base[chunk->count]
        kairo::construct_at<T>(unsafe (slot as unsafe *void))
        chunk->count += 1
        self._total += 1
        return slot
    }

    pub fn pop(self) -> T {
        if self._total == 0 {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                "ArenaList::pop: underflow on empty list",
            )

            kairo::std::ice_fail("ArenaList::pop: list is empty")
        }

        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        chunk->count -= 1
        self._total -= 1

        // Move out, then destroy the slot: a copy would leave the original
        // alive and never destroyed, and a move-only T (IntData and the other
        // Immediate payloads own a pointer) cannot be copied at all.
        var unsafe *slot = unsafe &chunk->base[chunk->count]
        var        val   = cxx::std::move(*slot)
        eval if !is_trivially_destructible!(T) {
            cxx::std::destroy_at(slot)
        }

        if chunk->count == 0 && self._chunk_count > 1 {
            self._chunk_count -= 1
        }

        return val
    }

    pub fn get(const self, idx: usize) -> unsafe *T {
        if idx >= self._total {
            return &null
        }

        var chunk  = idx / self._slab_size
        var offset = idx % self._slab_size
        return unsafe &self._chunks[chunk].base[offset]
    }

    fn back(const self) -> unsafe *T {
        if self._total == 0 {
            return &null
        }

        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        return unsafe &chunk->base[chunk->count - 1]
    }

    fn front(const self) -> unsafe *T {
        if self._total == 0 {
            return &null
        }

        return unsafe &self._chunks[0].base[0]
    }

    ///
    /// \brief Return a raw contiguous pointer to the first element.
    ///
    /// Only valid if slab_size >= total element count (single slab).
    /// Use freeze() for the safe multi-slab version that copies into
    /// a fresh contiguous block.
    ///
    fn raw(const self) -> unsafe *T {
        if self._chunk_count == 0 {
            return &null
        }

        return self._chunks[0].base
    }

    ///
    /// \brief Copy all elements into a fresh contiguous block allocated
    /// from the given arena, then return a pointer to it.
    ///
    /// Use this to bake the list into an AST node's fixed array field:
    ///
    ///   node->stmts     = list.freeze(ctx->node_arena);
    ///   node->num_stmts = list.size();
    ///
    /// After freeze() the list can be destroyed or cleared the frozen
    /// array lives in the target arena and is independent of this list.
    ///
    pub fn freeze(const self, arena: unsafe *ArenaAllocator) -> unsafe *T {
        if self._total == 0 {
            return &null
        }

        var arr = unsafe (arena->alloc(self._total * sizeof(T), alignof(T)) as unsafe *T)

        var dst: usize = 0
        for var c: usize = 0; c < self._chunk_count; ++c {
            var unsafe *chunk = unsafe &self._chunks[c]
            cxx::std::memcpy(
                arr + dst,
                chunk->base,
                chunk->count * sizeof(T)
                ,
            )

            dst += chunk->count
        }

        return arr
    }

    pub fn size(const self) -> usize {
        return self._total
    }

    pub fn empty(const self) -> bool {
        return self._total == 0
    }

    pub fn clear(self) {
        // chunk storage is allocated lazily on first push clear() on a
        // never-pushed list must be a no-op, not a null write to _chunks[0].
        if self._chunks == &null || self._chunk_count == 0 {
            self._total = 0
            return
        }

        eval if !is_trivially_destructible!(T) {
            for var c: usize = 0; c < self._chunk_count; ++c {
                for var i: usize = 0; i < self._chunks[c].count; ++i {
                    cxx::std::destroy_at(unsafe &self._chunks[c].base[i])
                }
            }
        }

        self._chunks[0].count = 0
        self._chunk_count     = 1
        self._total           = 0
    }

    fn clear_zero(self) {
        self._total       = 0
        self._chunk_count = 0
        self._arena->reset()
        self.alloc_descriptor_table(ARENA_LIST_DESCRIPTOR_INIT)
        self.alloc_slab()
    }

    fn destroy(self) {
        eval if !is_trivially_destructible!(T) {
            for var c: usize = 0; c < self._chunk_count; ++c {
                for var i: usize = 0; i < self._chunks[c].count; ++i {
                    cxx::std::destroy_at(unsafe &self._chunks[c].base[i])
                }
            }
        }

        self._chunks      = &null
        self._chunk_count = 0
        self._chunk_cap   = 0
        self._total       = 0

        // only destroy if we own the arena
        if self._arena == unsafe &self._owned_arena {
            self._owned_arena.destroy()
        }

        self._arena = &null
    }

    fn op finally(self) {
        self.destroy()
    }

    pub fn op [](const self, idx: usize) -> unsafe *T {
        if idx >= self._total {
            kairo::Logger::fatal(
                kairo::Logger::Stage::Driver,
                f"ArenaList::op[]: OOB idx={idx} size={self._total}",
            )

            kairo::std::ice_fail(
                f"ArenaList::operator[]: index {idx} out of bounds (size={self._total})",
            )
        }

        return self.get(idx)
    }

    priv fn ensure_space(self) {
        if self._chunk_count == 0 {
            self.alloc_slab()
            return
        }

        var unsafe *chunk = unsafe &self._chunks[self._chunk_count - 1]
        if chunk->count < chunk->capacity {
            return
        }

        self.alloc_slab()
    }

    priv fn alloc_slab(self) {
        if self._chunk_count >= self._chunk_cap {
            var new_cap = if (self._chunk_cap > 0) => (self._chunk_cap * 2)
                          else => ARENA_LIST_DESCRIPTOR_INIT
            var unsafe *new_table = unsafe (self._arena->alloc(new_cap * sizeof(Self::Chunk), alignof(Self::Chunk)) as unsafe *Self::Chunk)

            if self._chunks != &null {
                cxx::std::memcpy(new_table, self._chunks, self._chunk_count * sizeof(Self::Chunk))
            }

            self._chunks    = new_table
            self._chunk_cap = new_cap
        }

        var base = unsafe (self._arena->alloc(self._slab_size * sizeof(T), alignof(T)) as unsafe *T)

        self._chunks[self._chunk_count] = Self::Chunk {
            base:     base,
            count:    0,
            capacity: self._slab_size,
        }

        self._chunk_count += 1
    }

    priv fn alloc_descriptor_table(self, cap: usize) {
        self._chunks = unsafe (self._arena->alloc(cap * sizeof(Self::Chunk), alignof(Self::Chunk)) as unsafe *Self::Chunk)
        self._chunk_cap   = cap
        self._chunk_count = 0
    }
}
