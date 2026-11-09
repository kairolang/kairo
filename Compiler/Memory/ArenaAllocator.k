/// --- The Kairo Project ---------------------- Memory/ArenaAllocator.k --- ///
///
///   ArenaAllocator: a bump-pointer allocator over a chain of blocks.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/ArenaBlock.hh"
ffi "c++" import "Native/KPlacement.hh" // construct_at
ffi "c++" import "Native/Types.hh"
ffi "c++" import "cstddef"
ffi "c++" import "utility"
ffi "c++" import "algorithm"
ffi "c++" import "bit"

/// ArenaAllocator bump-pointer allocator backed by a linked chain of ArenaBlocks.
///
/// Design:
///   Maintains a singly-linked list of ArenaBlocks. Allocation tries the
///   head block first (single branch + addition); on exhaustion, a new
///   block is prepended to the chain. Prepend order means head is always
///   the newest/emptiest block, and destroy()/reset() walk the full chain
///   from head to tail without losing any blocks.
///
/// Block sourcing:
///   New blocks are requested from GlobalRecycler first (lock-free CAS,
///   zero syscall on cache hit). On recycler miss, falls back to
///   aligned_alloc. On destroy(), blocks are returned to the recycler
///   via ArenaBlock's destructor, not freed to the OS.
///
/// Expansion:
///   When the current head block is full, expand() allocates a new block
///   of max(block_size, bit_ceil(requested_size)) and prepends it. This
///   guarantees the new block can satisfy the allocation, and the old
///   chain remains reachable via head->next.
///
/// Reset modes:
///   reset()      walks the block chain, SIMD-zeroes each block up to
///                  its high-water mark. Use between compiler passes when
///                  you need clean memory (e.g., zeroed AST node pools).
///   reset_fast() walks the block chain, resets metadata only. O(blocks)
///                  but no memory traffic. Use when the next pass will
///                  overwrite all slots before reading (the common case).
///
/// Lifetime:
///   destroy() walks the chain and calls std::destroy on each block,
///   which returns the backing buffer to GlobalRecycler. After destroy(),
///   the allocator is dead no further allocations permitted.
///   shutdown() is the hard-teardown path: calls block->destroy() (raw
///   free, bypasses recycler) + frees the block struct itself.
///
/// Thread safety:
///   None by default: one allocator per thread. The only cross-thread
///   interaction is through GlobalRecycler, which takes its own lock.
///   An arena that several threads allocate from (a build-wide store whose
///   nodes carry ArenaLists any thread may grow: the instantiation
///   registry's shells, the canonical types) is shared(): every alloc()
///   then takes the owner's mutex. That lock nests under any lock its
///   caller holds: inside it alloc() takes only GlobalRecycler's
///   (a new block), itself a leaf that never waits on an arena.
///
/// Complexity:
///   alloc()      O(1), single bump or O(1) amortized with expand
///   reset()      O(total high_water bytes across all blocks)
///   reset_fast() O(blocks)
///   destroy()    O(blocks)
///
/// The first block of a lazily sized arena (ArenaAllocator's sized
/// constructor), doubled per block up to the arena's own size.
pub
const ARENA_FIRST_BLOCK: usize = 16 * 1024

pub class ArenaAllocator {
    struct Stats {
        var alloc_calls:     usize = 0
        var bytes_allocated: usize = 0
        var slab_count:      usize = 1
        var resets:          usize = 0
    }

    pub var stats: Self::Stats
    var     head:  unsafe *kairo::ArenaBlock
    /// u32, not usize: with grow they share the word _lock needs, so a
    /// shared arena costs no space in the millions of private ones (every
    /// ArenaList owns one). No block is 4 GiB.
    var block_size: u32
    /// The next block's size before block_size is reached (expand); 0 once
    /// it is, or for an arena made eagerly by init().
    var grow: u32 = 0
    /// shared(): the owner's mutex, taken by every alloc(); null for a
    /// private arena.
    var _lock: unsafe *kairo::std::Mutex = &null

    pub fn ArenaAllocator(self) {
        self.block_size = 1 << 10 // 1 KiB default block size
        self.head       = &null
    }

    /// \p blk_sz is the steady block size, reached by doubling from
    /// ARENA_FIRST_BLOCK: nothing is allocated until the first alloc(). Every
    /// ASTContext holds four sized arenas (ast 1 MiB, pp and index 64 KiB,
    /// strings), and the self-build makes ~1,550 of them for header files
    /// that hold a handful of decls each: allocated up front they were 1.9 GB
    /// of the peak, nearly all of it never used (perf pass).
    pub fn ArenaAllocator(self, blk_sz: usize) {
        self.head       = &null
        self.block_size = (blk_sz as u32)
        self.grow       = (cxx::std::min(blk_sz, ARENA_FIRST_BLOCK) as u32)
        // The first expand counts the first block, as the eager one was.
        self.stats.slab_count = 0
    }

    // The one transfer constructor (MOVE), so the one derived op = (self-check,
    // destroy, this body). Stage 0 also had a copy ctor and copy op = that
    // stole the same way; a MOVE class has neither, the move says it instead.
    @move fn ArenaAllocator(self, other: Self) {
        self.head       = other.head
        self.block_size = other.block_size
        self.grow       = other.grow
        self.stats      = other.stats
        self._lock      = other._lock
        other.head      = &null
    }

    /// init() without the block: the first alloc() makes it, \p blk_sz big.
    /// For an owner that may never allocate (ArenaList's own arena).
    fn init_lazy(self, blk_sz: usize) {
        if self.head != &null {
            self.destroy()
        }

        self.block_size = (blk_sz as u32)
        self.grow       = 0
    }

    fn init(self, blk_sz: usize) {
        if self.head != &null {
            self.destroy()
        }

        self.head       = kairo::std::create<kairo::ArenaBlock>(blk_sz)
        self.block_size = (blk_sz as u32)
        self.grow       = 0
    }

    fn op finally (self) {
        self.destroy()
    }

    /// Make every alloc() take \p mu, which outlives this arena: for an
    /// arena more than one thread allocates from (see the file header).
    pub fn shared(self, mu: unsafe *kairo::std::Mutex) {
        self._lock = mu
    }

    pub fn alloc(self, sz: usize, align: usize = alignof(cxx::std::max_align_t)) -> unsafe *void {
        if self._lock == &null {
            return self._alloc_impl(sz, align)
        }

        var lock = kairo::std::LockGuard(*self._lock)
        return self._alloc_impl(sz, align)
    }

    priv fn _alloc_impl(self, sz: usize, align: usize) -> unsafe *void {
        sz = if sz != 0 => sz else => 1

        ++self.stats.alloc_calls
        self.stats.bytes_allocated += sz

        if self.head == &null {
            return self.expand(sz, align)
        }

        var unsafe *p = self.head->try_alloc(sz, align)
        if p != &null {
            return p
        }

        return self.expand(sz, align)
    }

    // Allocate and construct a T in this arena. Kairo generics are not
    // variadic, so there is one overload per arity a caller uses; add one
    // when a new arity is needed. Arguments are taken by value and moved
    // into T's constructor: one copy at the call, as forwarding an lvalue
    // was. Placement itself is Native/KPlacement.hh.
    fn <T> create(self) -> unsafe *T {
        var mem: unsafe *void = self.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem)
    }

    pub fn <T, A0> alloc_init(self, a0: A0) -> unsafe *T {
        var mem: unsafe *void = self.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem, cxx::std::move(a0))
    }

    pub fn <T, A0, A1> alloc_init(self, a0: A0, a1: A1) -> unsafe *T {
        var mem: unsafe *void = self.alloc(sizeof(T), alignof(T))
        return kairo::construct_at<T>(mem, cxx::std::move(a0), cxx::std::move(a1))
    }

    pub fn reset(self) {
        ++self.stats.resets

        for var unsafe *b = self.head; b != &null; b = b->next {
            b->reset()
        }
    }

    pub fn reset_fast(self) {
        ++self.stats.resets

        for var unsafe *b = self.head; b != &null; b = b->next {
            b->reset_fast()
        }
    }

    pub fn destroy(self) {
        if self.head == &null {
            return
        }

        var unsafe *b = self.head
        while b != &null {
            var unsafe *next = b->next
            kairo::std::destroy(b)
            b = next
        }

        self.head = &null
    }

    pub fn shutdown(self) {
        var unsafe *b = self.head
        while b != &null {
            var unsafe *next = b->next
            b->destroy() // free the data buffer directly, sets ptr=null
            kairo::std::destroy(b) // ~ArenaBlock() sees ptr==null, skips recycler; uses aligned delete for the struct
            b = next
        }

        self.head = &null
    }

    struct Profile {
        pub var alloc_calls:     usize
        pub var bytes_allocated: usize
        pub var slab_count:      usize
        var     resets:          usize
    }

    pub fn profile(self) -> Self::Profile {
        return {
            .alloc_calls:     self.stats.alloc_calls,
            .bytes_allocated: self.stats.bytes_allocated,
            .slab_count:      self.stats.slab_count,
            .resets:          self.stats.resets
        }
    }

    priv fn expand(self, sz: usize, align: usize) -> unsafe *void {
        var step = (self.block_size as usize)
        if self.grow != 0 {
            step      = (self.grow as usize)
            self.grow = if (self.grow * 2 >= self.block_size) => (0) else => self.grow * 2
        }

        var        req  = cxx::std::max(step, cxx::std::bit_ceil(sz))
        var unsafe *blk = kairo::std::create<kairo::ArenaBlock>(req)

        // prepend new block becomes head, old chain reachable via next
        blk->next = self.head
        self.head = blk

        ++self.stats.slab_count
        return self.head->try_alloc(sz, align)
    }
}
