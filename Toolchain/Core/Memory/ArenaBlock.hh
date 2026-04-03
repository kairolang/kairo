#pragma once
#include <include/core.hh>

#include "../Types.hh"
#include "GlobalRecycler.hh"

namespace kairo {

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
///
struct alignas(64) ArenaBlock {
    std::Byte  *ptr;
    size_t      offset{};
    size_t      capacity;
    size_t      high_water{};
    ArenaBlock *next{};

    explicit ArenaBlock(size_t cap) noexcept
        : ptr(alloc_block(cap))
        , capacity(cap) {
        if constexpr (PRE_TOUCH) {
            pre_touch();
        }

        Logger::trace(Logger::Stage::Driver,
                      libcxx::format(L"ArenaBlock::ctor: cap={}B ptr={}",
                                     cap,
                                     static_cast<void *>(ptr)));
    }

    ~ArenaBlock() noexcept {
        if (ptr != nullptr) {
            GlobalRecycler::instance().push(ptr, capacity);
        }
    }

    ArenaBlock(const ArenaBlock &)            = delete;
    ArenaBlock &operator=(const ArenaBlock &) = delete;
    ArenaBlock(ArenaBlock &&)                 = delete;
    ArenaBlock &operator=(ArenaBlock &&)      = delete;

    void *try_alloc(size_t sz, size_t align) noexcept {
        size_t aligned = align_up(offset, align);

        if (aligned + sz > capacity) [[unlikely]] {
            Logger::trace(
                Logger::Stage::Driver,
                libcxx::format(
                    L"ArenaBlock::try_alloc: exhausted offset={} sz={} cap={}",
                    offset,
                    sz,
                    capacity));
            return nullptr;
        }

        void *p = ptr + aligned;
        offset  = aligned + sz;

        if (offset > high_water) [[unlikely]] {
            high_water = offset;
        }

        return p;
    }

    void destroy() noexcept {
        Logger::debug(Logger::Stage::Driver,
                      libcxx::format(L"ArenaBlock::destroy: hard-free cap={}B",
                                     capacity));
        libcxx::free(ptr);
        ptr = nullptr;
    }

#if defined(_x86_64_simd)
    [[gnu::target("avx512f")]]
    void reset_avx512(size_t len) noexcept {
        const __m512i zero = _mm512_setzero_si512();
        size_t        i    = 0;
        for (; i + 64 <= len; i += 64) {
            _mm512_stream_si512(reinterpret_cast<__m512i *>(ptr + i), zero);
        }
        if (i < len) {
            std::Memory::set(ptr + i, 0, len - i);
        }
        _mm_sfence();
    }
#endif

#if defined(_aarch64_simd)
    void reset_neon(size_t len) noexcept {
        size_t i = 0;

#if defined(__aarch64__)
        // Non-temporal store pair via inline asm - stnp q0, q1, [addr]
        // Zeroes 32 bytes per iteration without polluting the cache.
        const uint8x16_t zero = vdupq_n_u8(0);
        for (; i + 32 <= len; i += 32) {
            __asm__ volatile("stnp %q1, %q2, [%0]"
                             :
                             : "r"(ptr + i), "w"(zero), "w"(zero)
                             : "memory");
        }
#else
        // Fallback: temporal NEON stores (still vectorized, no stnp)
        const uint8x16_t zero = vdupq_n_u8(0);
        for (; i + 16 <= len; i += 16) {
            vst1q_u8(ptr + i, zero);
        }
#endif

        if (i < len) {
            std::Memory::set(ptr + i, 0, len - i);
        }
    }
#endif

    void reset() noexcept {
        if (high_water == 0) {
            offset = 0;
            return;
        }

        size_t len = high_water;
        offset     = 0;
        high_water = 0;

#if _simd_available()
        if (len < 4096) {
            std::Memory::set(ptr, 0, len);
            return;
        }
#if defined(_x86_64_simd)
        reset_avx512(len);
#elif defined(_aarch64_simd)
        reset_neon(len);
#else
        std::Memory::set(ptr, 0, len);
#endif
#else
        std::Memory::set(ptr, 0, len);
#endif
    }

    void reset_fast() noexcept {
        offset     = 0;
        high_water = 0;
    }

  private:
    static std::Byte *alloc_block(size_t cap) noexcept {
        cap = align_up(cap, 64);

        if (auto *blk = GlobalRecycler::instance().pop(cap)) {
            return blk;
        }

        return static_cast<std::Byte *>(
#ifndef _MSC_VER
            libcxx::aligned_alloc(64, cap)
#else
            _aligned_malloc(cap, 64)
#endif
        );
    }

    void pre_touch() const noexcept {
        constexpr size_t PAGE = 4096;

        for (size_t i = 0; i < capacity; i += PAGE) {
            ptr[i] = std::Byte{0};
        }
    }
};

}  // namespace kairo