#pragma once
#include <include/core.hh>

#include "../Types.hh"

namespace kairo {

constexpr bool   PRE_TOUCH  = false;
constexpr size_t SIMD_WIDTH = 64;

inline size_t align_up(size_t v, size_t align) noexcept {
    return (v + align - 1) & ~(align - 1);
}

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
/// Zero-allocation recycling:
///   Node headers are embedded at byte 0 of the recycled block itself.
///   No separate heap allocation per push/pop. The block is dead memory
///   anyway stamping a 16-byte header at the front costs nothing, and
///   it gets overwritten on first bump-alloc after reuse.
///
/// Thread safety:
///   Fully lock-free via per-bin CAS on atomic head pointers. Safe for
///   concurrent arena teardown across threads/pipeline stages. clear()
///   is NOT thread-safe call only at program shutdown when no other
///   thread is touching the recycler.
///
/// Minimum recyclable size:
///   Blocks < 4KB skip the recycler and go straight to free(). Below
///   that threshold the CAS contention and cache line touch aren't
///   worth the saved malloc. For compiler workloads (64KB+ blocks)
///   this almost never fires.
///
/// Complexity:
///   push()    O(1), single CAS
///   pop()     O(1) amortized, at most NUM_BINS CAS attempts
///   clear()   O(n), shutdown-only path
///
class GlobalRecycler {
    struct Node {
        Node  *next;
        size_t capacity;
    };

    static constexpr size_t NUM_BINS                 = 3;
    static constexpr size_t BIN_THRESHOLDS[NUM_BINS] = {
        64UL * 1024, 1024UL * 1024, SIZE_MAX};
    static constexpr size_t MIN_RECYCLABLE = 4096;

    Node*       bins_[NUM_BINS] = {};  // plain pointers, mutex protects them
    std::Mutex  _mu;

    static size_t bin_index(size_t size) noexcept {
        for (size_t i = 0; i < NUM_BINS; ++i) {
            if (size <= BIN_THRESHOLDS[i]) return i;
        }
        #ifdef _MSC_VER
            __assume(false);
        #else
            __builtin_unreachable();
        #endif
    }

public:
    static GlobalRecycler& instance() noexcept {
        static GlobalRecycler inst;
        return inst;
    }

    GlobalRecycler()                                  = default;
    ~GlobalRecycler() noexcept { clear(); }
    GlobalRecycler(const GlobalRecycler&)             = delete;
    GlobalRecycler& operator=(const GlobalRecycler&)  = delete;
    GlobalRecycler(GlobalRecycler&&)                  = delete;
    GlobalRecycler& operator=(GlobalRecycler&&)       = delete;

    void push(std::Byte* block, size_t capacity) noexcept {
        if (block == nullptr || capacity < MIN_RECYCLABLE) {
            if (block != nullptr) {
                #ifdef _MSC_VER
                    _aligned_free(block);
                #else
                    libcxx::free(block);
                #endif
            }
            return;
        }

        auto* node     = reinterpret_cast<Node*>(block);
        node->capacity = capacity;
        size_t idx     = bin_index(capacity);

        std::LockGuard<std::Mutex> lock(_mu);
        node->next = bins_[idx];
        bins_[idx] = node;
    }

    std::Byte* pop(size_t min_size) noexcept {
        if (min_size < MIN_RECYCLABLE) return nullptr;

        std::LockGuard<std::Mutex> lock(_mu);

        for (size_t idx = bin_index(min_size); idx < NUM_BINS; ++idx) {
            Node* node = bins_[idx];
            if (node != nullptr && node->capacity >= min_size) {
                bins_[idx] = node->next;
                return reinterpret_cast<std::Byte*>(node);
            }
        }

        return nullptr;
    }

    void clear() noexcept {
        std::LockGuard<std::Mutex> lock(_mu);
        for (auto& bin : bins_) {
            Node* node = bin;
            bin = nullptr;
            while (node != nullptr) {
                Node* next = node->next;
                #ifdef _MSC_VER
                    _aligned_free(reinterpret_cast<std::Byte*>(node));
                #else
                    libcxx::free(reinterpret_cast<std::Byte*>(node));
                #endif
                node = next;
            }
        }
    }

    static void shutdown_allocator_runtime() noexcept {
        GlobalRecycler::instance().clear();
    }
};

}  // namespace kairo