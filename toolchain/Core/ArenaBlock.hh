#pragma once

#include <include/core.hh>

#include "GlobalRecycler.hh"
#include "Types.hh"

namespace helix {
struct alignas(64) ArenaBlock {
    std::Byte  *ptr;
    size_t      offset;
    size_t      capacity;
    ArenaBlock *next;

    explicit ArenaBlock(size_t cap) noexcept
        : ptr(alloc_block(cap))
        , offset(0)
        , capacity(cap)
        , next(nullptr) {
        if constexpr (PRE_TOUCH) {
            pre_touch();
        }
    }

    ~ArenaBlock() noexcept { GlobalRecycler::instance().push(ptr, capacity); }

    ArenaBlock(const ArenaBlock &)            = delete;
    ArenaBlock &operator=(const ArenaBlock &) = delete;
    ArenaBlock(ArenaBlock &&)                 = delete;
    ArenaBlock &operator=(ArenaBlock &&)      = delete;

    void *try_alloc(size_t sz, size_t align) noexcept {
        size_t aligned = align_up(offset, align);
        
        if (aligned + sz > capacity) {
            return nullptr;
        }

        void *p = ptr + aligned;
        offset  = aligned + sz;
        
        return p;
    }

    void reset() noexcept {
        offset = 0;
#if _simd_available()
        if (capacity < 4096) {
            std::Memory::set(ptr, 0, capacity);
            return;
        }
#   if defined(_x86_64_simd)
        const __m512i zero = _mm512_setzero_si512();
        size_t        i    = 0;

        for (; i + SIMD_WIDTH <= capacity; i += SIMD_WIDTH) {
            _mm512_stream_si512(reinterpret_cast<__m512i *>(ptr + i), zero);
        }

        _mm_sfence();
#   elif defined(_aarch64_simd)
        uint8x16_t zero = vdupq_n_u8(0);
        
        for (size_t i = 0; i + 16 <= capacity; i += 16) {
            vst1q_u8(reinterpret_cast<uint8_t *>(ptr + i), zero);
        }
#   endif
#else
        std::Memory::set(ptr, 0, capacity);
#endif
    }

  private:
    static std::Byte *alloc_block(size_t cap) noexcept {
        if (auto *blk = GlobalRecycler::instance().pop(cap)) {
            return blk;
        }

        return static_cast<std::Byte *>(libcxx::aligned_alloc(64, cap));
    }

    void pre_touch() const noexcept {
        if constexpr (!PRE_TOUCH) {
            return;
        }

        constexpr size_t PAGE = 4096;

        for (size_t i = 0; i < capacity; i += PAGE) {
            ptr[i] = std::Byte{0};
        }
    }
};
}  // namespace helix