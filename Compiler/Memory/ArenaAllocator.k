/// --- The Kairo Project ---------------------- Memory/ArenaAllocator.k --- ///
///
///   <short description>
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/ArenaBlock.hh";
ffi "c++" import "Native/KPlacement.hh";   // construct_at

import Support::Timer::*;

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
///   None. One allocator per thread. The only cross-thread interaction
///   is through GlobalRecycler, which is internally lock-free.
///
/// Complexity:
///   alloc()      O(1), single bump or O(1) amortized with expand
///   reset()      O(total high_water bytes across all blocks)
///   reset_fast() O(blocks)
///   destroy()    O(blocks)
///
class ArenaAllocator {
    struct Stats {
        var alloc_calls:     usize = 0;
        var bytes_allocated: usize = 0;
        var slab_count:      usize = 1;
        var resets:          usize = 0;
    }

    pub var stats:      Stats;
    var head:           own::<ArenaBlock>;
    var block_size:     usize;

    fn ArenaAllocator(self) {
        self.block_size = (1 << 10); // 1 KiB default block size
        self.head = &null;
    }

    fn ArenaAllocator(self, blk_sz: usize) {
        (self.head)     = std::create::<ArenaBlock>(blk_sz);
        self.block_size = blk_sz;
    }

    // move and copy constructor
    fn ArenaAllocator(self, other: ref!(ArenaAllocator)) {
        self.head       = other.head;
        self.block_size = other.block_size;
        self.stats      = other.stats;
        (other.head)    = &null;
    }

    fn ArenaAllocator(self, other: mref!(ArenaAllocator)) {
        self.head       = other.head;
        self.block_size = other.block_size;
        self.stats      = other.stats;
        (other.head)    = &null;
    }

    fn op = (self, other: ref!(ArenaAllocator)) {
        if (&self) != (&other) {
            self.destroy();
            self.head       = other.head;
            self.block_size = other.block_size;
            self.stats      = other.stats;
            (other.head)    = &null;
        }
    }

    fn op = (self, other: mref!(ArenaAllocator)) {
        if (&self) != (&other) {
            self.destroy();
            self.head       = other.head;
            self.block_size = other.block_size;
            self.stats      = other.stats;
            (other.head)    = &null;
        }
    }

    /// init() without the block: the first alloc() makes it, \p blk_sz big.
    /// For an owner that may never allocate (ArenaList's own arena, P380).
    fn init_lazy(self, blk_sz: usize) {
        if (self.head) != (&null) {
            self.destroy();
        }
        self.block_size = blk_sz;
    }

    fn init(self, blk_sz: usize) {
        if (self.head) != (&null) {
            self.destroy();
        }
        self.head       = std::create::<ArenaBlock>(blk_sz);
        self.block_size = blk_sz;
    }

    fn op delete (self) {
        self.destroy();
    }

    fn alloc(self, sz: usize, align: usize = alignof(libcxx::max_align_t)) -> *void {
        sz = sz if sz != 0 else 1;

        ++(self.stats.alloc_calls);
        (self.stats.bytes_allocated) += sz;

        if (self.head) == (&null) {
            return self.expand(sz, align);
        }

        var p = (self.head)->try_alloc(sz, align);
        if (p != &null) {
            return p;
        }

        return self.expand(sz, align);
    }

    // Allocate and construct a T in this arena. Kairo generics are not
    // variadic, so there is one overload per arity a caller uses; add one
    // when a new arity is needed. Arguments are taken by value and moved
    // into T's constructor: one copy at the call, as forwarding an lvalue
    // was. Placement itself is Native/KPlacement.hh.
    fn <T> create(self) -> *T {
        var mem: *void = self.alloc(sizeof(T), alignof(T));
        return kairo::construct_at::<T>(mem);
    }

    fn <T, A0> alloc_init(self, a0: A0) -> *T {
        var mem: *void = self.alloc(sizeof(T), alignof(T));
        return kairo::construct_at::<T>(mem, std::Memory::move(a0));
    }

    fn <T, A0, A1> alloc_init(self, a0: A0, a1: A1) -> *T {
        var mem: *void = self.alloc(sizeof(T), alignof(T));
        return kairo::construct_at::<T>(mem, std::Memory::move(a0), std::Memory::move(a1));
    }

    fn reset(self) {
        ++(self.stats.resets);

        for var b = (self.head); b != &null; b = b->next {
            b->reset();
        }
    }

    fn reset_fast(self) {
        ++(self.stats.resets);

        for var b = (self.head); b != &null; b = b->next {
            b->reset_fast();
        }
    }

    fn destroy(self) {
        if self.head == &null {
            return;
        }

        var b = self.head;
        while (b != &null) {
            var next = b->next;
            std::destroy(b);
            b = next;
        }

        self.head = &null;
    }

    fn shutdown(self) {
        var b = (self.head);
        while (b != &null) {
            var next = b->next;
            b->destroy();     // free the data buffer directly, sets ptr=null
            std::destroy(b);  // ~ArenaBlock() sees ptr==null, skips recycler; uses aligned delete for the struct
            b = next;
        }
        (self.head) = &null;
    }

    struct Profile {
        var alloc_calls:     usize;
        var bytes_allocated: usize;
        var slab_count:      usize;
        var resets:          usize;
    }

    fn profile(self) -> Profile {
        return {
            .alloc_calls:     self.stats.alloc_calls,
            .bytes_allocated: self.stats.bytes_allocated,
            .slab_count:      self.stats.slab_count,
            .resets:          self.stats.resets
        };
    }

    priv fn expand(self, sz: usize, align: usize) -> *void {
        var req = libcxx::max(self.block_size, libcxx::bit_ceil(sz));
        var blk = std::create::<ArenaBlock>(req);

        // prepend new block becomes head, old chain reachable via next
        (blk->next) = (self.head);
        ((self.head)) = blk;

        ++(self.stats.slab_count);
        return (self.head)->try_alloc(sz, align);
    }
}

