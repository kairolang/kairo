/// --- The Kairo Project -------------------------- Native/ArenaBlock.k --- ///
///
///   ArenaBlock: one contiguous slab of an ArenaAllocator, with bump
///   allocation. Its SIMD zeroing is Native/ArenaBlock.hh.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/ArenaBlock.hh" // arena_reset_zero
ffi "c++" import "Native/Types.hh" // Byte, out_of_memory
ffi "c++" import "Native/Log.hh"

import Native::GlobalRecycler::{
    BLOCK_ALIGN,
    GlobalRecycler,
    PRE_TOUCH,
    align_up,
}

/// ArenaBlock a single contiguous memory slab with bump allocation.
///
/// design:
///   each block is a flat byte buffer with a bump pointer (offset).
///   allocation is a single addition + bounds check no free lists,
///   no headers, no fragmentation. alignment is handled by rounding
///   the offset up before bumping.
///
/// lifecycle:
///   blocks are allocated via globalrecycler (cache hit) or
///   aligned_alloc (cache miss). on destruction, the backing buffer
///   is returned to the recycler, not freed it will be reused by
///   the next arenaallocator that requests a block of similar size.
///   destroy() bypasses the recycler and calls free() directly;
///   used only by arenaallocator::shutdown() for hard teardown.
///
/// reset:
///   reset()      zeros memory up to high_water via simd (avx-512
///                  on x86, neon stnp on arm), then resets offset.
///                  only touches bytes that were actually allocated,
///                  not the full capacity.
///   reset_fast() o(1) metadata reset, no zeroing. use when the
///                  caller will overwrite all memory before reading
///                  (the common case in compiler pass reuse).
///
/// high-water tracking:
///   high_water records the maximum offset ever reached. this lets
///   reset() skip zeroing untouched tail memory. updated on the
///   allocation hot path with a branch-predicted unlikely check
///   once the block is warmed up, the branch never fires.
///
/// thread safety:
///   none. a block is owned by exactly one arenaallocator on one
///   thread. this is intentional adding atomics to the bump
///   pointer would destroy the performance advantage of arena
///   allocation. for cross-thread work, use one allocator per thread.
///
/// memory layout:
///   [ptr ............................ ptr + capacity]
///    ^--- offset (bump pointer)
///    ^--- high_water (max offset ever seen)
///
/// complexity:
///   try_alloc()  o(1), single branch + addition
///   reset()      o(high_water), simd-accelerated
///   reset_fast() o(1)
///   destroy()    o(1)
@align(64)
pub class ArenaBlock {
    pub var ptr:        unsafe *kairo::std::Byte         ///< view
    pub var offset:     usize                    = 0
    pub var capacity:   usize
    pub var high_water: usize                    = 0
    pub var next:       unsafe *ArenaBlock       = &null ///< obs

    /// alloc_block rewrites `cap` to the block's TRUE capacity before
    /// `capacity` records it: do not "simplify" this back to recording the
    /// requested size   see alloc_block below.
    pub fn ArenaBlock(self, cap: usize) {
        var got: usize = cap
        self.ptr      = Self::alloc_block(&got)
        self.capacity = got
        eval if PRE_TOUCH {
            self.pre_touch()
        }
    }

    fn op finally (self) {
        if self.ptr != &null {
            GlobalRecycler::instance()->push(self.ptr, self.capacity)
        }
    }

    @copy
    fn ArenaBlock(self, const other: Self) = delete

    @move
    fn ArenaBlock(self, other: Self) = delete

    pub inline fn try_alloc(self, sz: usize, align: usize) -> unsafe *void {
        const aligned: usize = align_up(self.offset, align)

        @unlikely
        if aligned + sz > self.capacity {
            return &null
        }

        var unsafe *p = unsafe ((self.ptr + aligned) as unsafe *void)
        self.offset = aligned + sz

        @unlikely
        if self.offset > self.high_water {
            self.high_water = self.offset
        }

        return p
    }

    pub fn destroy(self) {
        kairo::Logger::debug(
            kairo::Logger::Stage::Driver,
            f"ArenaBlock::destroy: hard-free cap={self.capacity}B",
        )

        GlobalRecycler::free_raw(self.ptr)
        self.ptr = &null
    }

    pub fn reset(self) {
        if self.high_water == 0 {
            self.offset = 0
            return
        }

        const len: usize = self.high_water
        self.offset     = 0
        self.high_water = 0

        kairo::arena_reset_zero(self.ptr, len)
    }

    pub fn reset_fast(self) {
        self.offset     = 0
        self.high_water = 0
    }

    /// `cap` is IN/OUT. In: the requested size. Out: the capacity actually
    /// obtained, which is >= the request when the recycler satisfies it from
    /// a larger size class.
    ///
    /// The caller MUST adopt the out value. Recording the request instead
    /// means the block is pushed back into a smaller bin on teardown,
    /// permanently demoting it   large blocks drain away one pass at a time
    /// and every large allocation mallocs fresh, which reads as an unbounded
    /// leak.
    priv static fn alloc_block(@inout cap: usize) -> unsafe *kairo::std::Byte {
        cap = align_up(cap, BLOCK_ALIGN)

        var        got:      usize = 0
        var unsafe *recycled       = GlobalRecycler::instance()->pop(cap, &got)
        if recycled != &null {
            cap = got
            return recycled
        }

        var unsafe *blk = GlobalRecycler::alloc_raw(cap)
        // try_alloc does not test `ptr`: a null block with a capacity would
        // hand out small integers as pointers.
        @unlikely
        if blk == &null {
            kairo::std::out_of_memory(cap)
        }

        return blk
    }

    priv fn pre_touch(const self) {
        eval PAGE: usize = 4096

        for var i: usize = 0; i < self.capacity; i += PAGE {
            self.ptr[i] = ((0 as u8) as kairo::std::Byte)
        }
    }
}
