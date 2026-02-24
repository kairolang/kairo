#pragma once
#include <include/core.hh>

#include "Types.hh"

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

    static_assert(sizeof(Node) <= 64, "Node must fit in a cache line");

    static constexpr size_t NUM_BINS                 = 3;
    static constexpr size_t BIN_THRESHOLDS[NUM_BINS] = {
        64UL * 1024, 1024UL * 1024, SIZE_MAX};

    std::Atomic<Node *> bins_[NUM_BINS] = {};

    static size_t bin_index(size_t size) noexcept {
        for (size_t i = 0; i < NUM_BINS; ++i) {
            if (size <= BIN_THRESHOLDS[i]) {
                return i;
            }
        }
        __builtin_unreachable();
    }

    static constexpr size_t MIN_RECYCLABLE = 4096;

  public:
    static GlobalRecycler &instance() noexcept {
        static GlobalRecycler inst;
        return inst;
    }

    GlobalRecycler() = default;
    ~GlobalRecycler() noexcept { clear(); }

    GlobalRecycler(const GlobalRecycler &)            = delete;
    GlobalRecycler &operator=(const GlobalRecycler &) = delete;
    GlobalRecycler(GlobalRecycler &&)                 = delete;
    GlobalRecycler &operator=(GlobalRecycler &&)      = delete;

    void push(std::Byte *block, size_t capacity) noexcept {
        if (block == nullptr || capacity < MIN_RECYCLABLE) [[unlikely]] {
            if (block != nullptr) {
                libcxx::free(block);
            }

            return;
        }

        if (capacity < MIN_RECYCLABLE) [[unlikely]] {
            libcxx::free(block);
            return;
        }

        auto *node     = reinterpret_cast<Node *>(block);
        node->capacity = capacity;

        size_t idx = bin_index(capacity);

        node->next = bins_[idx].load(std::MemoryOrder::relaxed);
        while (!bins_[idx].compare_exchange_weak(node->next,
                                                 node,
                                                 std::MemoryOrder::release,
                                                 std::MemoryOrder::relaxed)) {
            ;  // spin until we successfully push the node onto the bin's linked
               // list
        }
    }

    std::Byte *pop(size_t min_size) noexcept {
        if (min_size < MIN_RECYCLABLE) {
            return nullptr;
        }

        for (size_t idx = bin_index(min_size); idx < NUM_BINS; ++idx) {
            Node *node = bins_[idx].load(std::MemoryOrder::acquire);

            while (node != nullptr) {
                if (node->capacity >= min_size) {
                    if (bins_[idx].compare_exchange_weak(
                            node,
                            node->next,
                            std::MemoryOrder::acq_rel,
                            std::MemoryOrder::relaxed)) {
                        return reinterpret_cast<std::Byte *>(node);
                    }
                    continue;
                }
                break;
            }
        }

        return nullptr;
    }

    void clear() noexcept {
        for (auto &bin : bins_) {
            Node *node = bin.exchange(nullptr, std::MemoryOrder::acq_rel);
            while (node != nullptr) {
                Node *next = node->next;
                libcxx::free(reinterpret_cast<std::Byte *>(node));
                node = next;
            }
        }
    }

    static void shutdown_allocator_runtime() noexcept {
        GlobalRecycler::instance().clear();
    }
};

}  // namespace kairo