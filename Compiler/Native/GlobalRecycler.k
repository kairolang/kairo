/// --- The Kairo Project ---------------------- Native/GlobalRecycler.k --- ///
///
///   The process-wide recycler of arena blocks, and the block constants the
///   arenas share.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/Types.hh" // Atomic, Byte, Mutex, LockGuard
ffi "c++" import "atomic"
ffi "c++" import "cstdlib"
ffi "c++" import "cstring"

pub eval PRE_TOUCH: bool = false

/// Alignment of every arena block: a cache line, and what the AVX-512
/// streaming reset stores to.
pub eval BLOCK_ALIGN: usize = 64

pub inline fn align_up(v: usize, align: usize) -> usize {
    return (v + align - 1) & ~(align - 1)
}

/// GlobalRecycler's bins. File scope: an eval array cannot be a class
/// member's initializer.
priv eval NUM_BINS:       usize      = 3
priv eval BIN_THRESHOLDS: [usize; 3] = [64 * 1024, 1024 * 1024, usize::MAX]
priv eval MIN_RECYCLABLE: usize      = 4096

/// Per-bin retention ceiling. Sized to hold a comfortable working set of
/// live arenas without letting a spike become permanent residency.
priv eval MAX_BIN_BYTES: [usize; 3] = [16 * 1024 * 1024, 64 * 1024 * 1024, 64 * 1024 * 1024]

/// Nodes examined per bin before giving up on it. Bins are near-homogeneous
/// in practice (one size class per arena kind), so the first node almost
/// always fits; the bound just keeps a pathological mix O(1) instead of
/// walking a list that can hold thousands of blocks.
priv eval MAX_SCAN: usize = 8

/// GlobalRecycler lock-free, bin-based block recycler for arena allocators.
///
/// Design:
///   Freed arena blocks are recycled into size-class bins rather than
///   returned to the OS via free(). When an ArenaAllocator needs a new
///   block, it checks the recycler first, avoiding the syscall/malloc
///   overhead entirely on cache hit.
///
/// Bins:
///   3 size classes ≤64KB (descriptor tables, scratch), ≤1MB (default
///   arena blocks, token/AST slabs), >1MB (large TU IR buffers). push()
///   routes by capacity, pop() searches from the target bin upward.
///
/// TRUE CAPACITY. pop() reports the capacity of the block it actually
/// handed back, which may EXCEED what the caller asked for (an exact-bin
/// miss falls through to a larger bin). The caller MUST record that value
/// as the block's capacity, not its own request:
///   - push()ing it back under the smaller requested size permanently
///     demotes the block into a lower bin. Repeated across passes that
///     drains the large bins and forces a fresh malloc for every large
///     allocation, while the demoted blocks pile up unusable: an
///     unbounded leak.
///   - the surplus bytes are usable. A 1MB block serving a 64KB request
///     is only wasteful if the arena is told it has 64KB.
///
/// Zero-allocation recycling:
///   Node headers are embedded at byte 0 of the recycled block itself.
///   No separate heap allocation per push/pop. The block is dead memory
///   anyway stamping a 16-byte header at the front costs nothing, and
///   it gets overwritten on first bump-alloc after reuse.
///
/// Retention cap:
///   Each bin retains at most MAX_BIN_BYTES; past that, push() frees to
///   the OS instead of caching. Without a cap the recycler is a one-way
///   ratchet   a single large batch grows the pool and nothing ever
///   gives it back, so peak footprint becomes permanent footprint.
///
/// Thread safety:
///   A single mutex guards all bins. Safe for concurrent arena teardown
///   across threads/pipeline stages. clear() is NOT thread-safe call
///   only at program shutdown when no other thread is touching the
///   recycler.
///
/// Minimum recyclable size:
///   Blocks < 4KB skip the recycler and go straight to free(). Below
///   that threshold the lock traffic and cache line touch aren't worth
///   the saved malloc. For compiler workloads (64KB+ blocks) this almost
///   never fires.
///
/// Complexity:
///   push()    O(1)
///   pop()     O(1)   at most MAX_SCAN nodes per bin, NUM_BINS bins
///   clear()   O(n), shutdown-only path
pub class GlobalRecycler {
    struct Node {
        var next:     unsafe *Self ///< own
        var capacity: usize
    }

    var bins_:      [unsafe *Self::Node; 3] = [&null, &null, &null] // plain pointers, mutex protects them
    var bin_bytes_: [usize; 3]              = [0, 0, 0] // retained bytes, per bin
    var _mu:        kairo::std::Mutex

    static fn bin_index(size: usize) -> usize {
        for var i: usize = 0; i < NUM_BINS; ++i {
            if size <= BIN_THRESHOLDS[i] {
                return i
            }
        }

        // Every size is <= the last threshold (usize::MAX). The compiler
        // is clang on every target, MSVC's included.
        unsafe {
            __builtin_unreachable()
        }
    }

    pub static fn instance() -> unsafe *GlobalRecycler {
        static inst: GlobalRecycler
        return unsafe &inst
    }

    pub fn GlobalRecycler(self) { }

    fn op finally (self) {
        self.clear()
    }

    @copy
    fn GlobalRecycler(self, const other: Self) = delete

    @move
    fn GlobalRecycler(self, other: Self) = delete

    /// Zero every block on its way out of an arena. A live check's heap
    /// scan (KAIRO_LIVE_POISON, Native/Shims.hh) takes any word for a
    /// pointer; a block handed out again still holds what its last owner
    /// wrote, in whatever the new one has not written yet.
    pub static scrub: kairo::std::Atomic<bool> = kairo::std::Atomic<bool>(false)

    /// A fresh block of `size` bytes (a multiple of BLOCK_ALIGN), or null.
    /// Windows' CRTs (MSVC's and MinGW's msvcrt / ucrt alike) have no C11
    /// aligned_alloc, and _aligned_malloc's blocks go back only through
    /// _aligned_free: every block is made here and released by free_raw.
    pub static fn alloc_raw(size: usize) -> unsafe *kairo::std::Byte {
        eval if defined!(_WIN32) {
            return unsafe (_aligned_malloc(size, BLOCK_ALIGN) as unsafe *kairo::std::Byte)
        } else {
            return unsafe (cxx::std::aligned_alloc(BLOCK_ALIGN, size) as unsafe *kairo::std::Byte)
        }
    }

    pub static fn free_raw(block: unsafe *void) {
        eval if defined!(_WIN32) {
            _aligned_free(block)
        } else {
            cxx::std::free(block)
        }
    }

    pub fn stats(self, @inout out_blocks: usize, @inout out_bytes: usize) {
        var lock = kairo::std::LockGuard<kairo::std::Mutex>(&self._mu)
        out_blocks = 0
        out_bytes  = 0
        for var i: usize = 0; i < NUM_BINS; ++i {
            for var unsafe *n = self.bins_[i]; n != &null; n = n->next {
                ++out_blocks
                out_bytes += n->capacity
            }
        }
    }

    /// `capacity` is the block's TRUE capacity, as reported by pop() or as
    /// passed to the allocation that produced it. Passing a smaller value
    /// permanently demotes the block   see the class docs.
    pub fn push(self, block: unsafe *kairo::std::Byte, capacity: usize) {
        if block == &null {
            return
        }

        if GlobalRecycler::scrub.load(cxx::std::memory_order_relaxed) {
            cxx::std::memset(block, 0, capacity)
        }

        if capacity >= MIN_RECYCLABLE {
            const idx: usize = Self::bin_index(capacity)

            var lock = kairo::std::LockGuard<kairo::std::Mutex>(&self._mu)
            if self.bin_bytes_[idx] + capacity <= MAX_BIN_BYTES[idx] {
                var unsafe *node = unsafe (block as unsafe *Self::Node)
                node->capacity  = capacity
                node->next      = self.bins_[idx]
                self.bins_[idx] = node
                self.bin_bytes_[idx] += capacity
                return
            }

            // bin is full   fall through and give the pages back to the OS.
        }

        Self::free_raw(block)
    }

    /// `out_capacity` receives the capacity of the returned block, which may
    /// be LARGER than `min_size`. Untouched on miss. The caller must adopt
    /// this value as the block's capacity.
    pub fn pop(self, min_size: usize, @inout out_capacity: usize) -> unsafe *kairo::std::Byte {
        if min_size < MIN_RECYCLABLE {
            return &null
        }

        var lock = kairo::std::LockGuard<kairo::std::Mutex>(&self._mu)

        for var idx: usize = Self::bin_index(min_size); idx < NUM_BINS; ++idx {
            var        prev: unsafe *Self::Node = &null
            var unsafe *node                    = self.bins_[idx]

            // Walk, don't just peek: a single undersized block at the head
            // would otherwise mask every fitting block behind it, and every
            // later push would pile onto a bin that can never be drained.
            for var n: usize = 0; node != &null && n < MAX_SCAN; ++n {
                if node->capacity >= min_size {
                    if prev == &null {
                        self.bins_[idx] = node->next
                    } else {
                        prev->next = node->next
                    }

                    self.bin_bytes_[idx] -= node->capacity
                    out_capacity = node->capacity
                    return unsafe (node as unsafe *kairo::std::Byte)
                }

                prev = node
                node = node->next
            }
        }

        return &null
    }

    pub fn clear(self) {
        var lock = kairo::std::LockGuard<kairo::std::Mutex>(&self._mu)
        for var i: usize = 0; i < NUM_BINS; ++i {
            self.bin_bytes_[i] = 0
        }

        for var i: usize = 0; i < NUM_BINS; ++i {
            var unsafe *node = self.bins_[i]
            self.bins_[i] = &null
            while node != &null {
                var unsafe *next = node->next
                Self::free_raw(node)
                node = next
            }
        }
    }

    pub static fn shutdown_allocator_runtime() {
        GlobalRecycler::instance()->clear()
    }
}
