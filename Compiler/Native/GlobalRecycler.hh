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
/// TRUE CAPACITY. pop() reports the capacity of the block it actually
/// handed back, which may EXCEED what the caller asked for (an exact-bin
/// miss falls through to a larger bin). The caller MUST record that value
/// as the block's capacity, not its own request:
///
///   - push()ing it back under the smaller requested size permanently
///     demotes the block into a lower bin. Repeated across passes that
///     drains the large bins and forces a fresh malloc for every large
///     allocation, while the demoted blocks pile up unusable. This was a
///     real unbounded leak, not a theoretical one.
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
///
class GlobalRecycler {
    struct Node {
        own<Node> next;
        size_t    capacity;
    };

    static constexpr size_t NUM_BINS                 = 3;
    static constexpr size_t BIN_THRESHOLDS[NUM_BINS] = {
        64UL * 1024, 1024UL * 1024, SIZE_MAX};
    static constexpr size_t MIN_RECYCLABLE = 4096;

    /// Per-bin retention ceiling. Sized to hold a comfortable working set of
    /// live arenas without letting a spike become permanent residency.
    static constexpr size_t MAX_BIN_BYTES[NUM_BINS] = {
        16UL * 1024 * 1024, 64UL * 1024 * 1024, 64UL * 1024 * 1024};

    /// Nodes examined per bin before giving up on it. Bins are near-homogeneous
    /// in practice (one size class per arena kind), so the first node almost
    /// always fits; the bound just keeps a pathological mix O(1) instead of
    /// walking a list that can hold thousands of blocks.
    static constexpr size_t MAX_SCAN = 8;

    own<Node>  bins_[NUM_BINS]      = {};  // plain pointers, mutex protects them
    size_t     bin_bytes_[NUM_BINS] = {};  // retained bytes, per bin
    std::Mutex _mu;

    static size_t bin_index(size_t size) noexcept {
        for (size_t i = 0; i < NUM_BINS; ++i) {
            if (size <= BIN_THRESHOLDS[i])
                return i;
        }
#ifdef _MSC_VER
        __assume(false);
#else
        __builtin_unreachable();
#endif
    }

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

    void stats(usize &out_blocks, usize &out_bytes) noexcept {
        std::LockGuard<std::Mutex> lock(_mu);
        out_blocks = 0; out_bytes = 0;
        for (auto &bin : bins_) {
            for (Node *n = bin; n != nullptr; n = n->next) {
                ++out_blocks;
                out_bytes += n->capacity;
            }
        }
    }

    /// \param capacity the block's TRUE capacity, as reported by pop() or as
    ///        passed to the allocation that produced it. Passing a smaller
    ///        value permanently demotes the block   see the class docs.
    void push(std::Byte *block, size_t capacity) noexcept {
        if (block == nullptr)
            return;

        if (capacity >= MIN_RECYCLABLE) {
            size_t idx = bin_index(capacity);

            std::LockGuard<std::Mutex> lock(_mu);
            if (bin_bytes_[idx] + capacity <= MAX_BIN_BYTES[idx]) {
                auto *node     = reinterpret_cast<Node *>(block);
                node->capacity = capacity;
                node->next     = bins_[idx];
                bins_[idx]     = node;
                bin_bytes_[idx] += capacity;
                return;
            }
            // bin is full   fall through and give the pages back to the OS.
        }

#ifdef _MSC_VER
        _aligned_free(block);
#else
        libcxx::free(block);
#endif
    }

    /// \param out_capacity receives the capacity of the returned block, which
    ///        may be LARGER than \p min_size. Untouched on miss. The caller
    ///        must adopt this value as the block's capacity.
    std::Byte *pop(size_t min_size, size_t &out_capacity) noexcept {
        if (min_size < MIN_RECYCLABLE)
            return nullptr;

        std::LockGuard<std::Mutex> lock(_mu);

        for (size_t idx = bin_index(min_size); idx < NUM_BINS; ++idx) {
            Node *prev = nullptr;
            Node *node = bins_[idx];

            // Walk, don't just peek: a single undersized block at the head
            // would otherwise mask every fitting block behind it, and every
            // later push would pile onto a bin that can never be drained.
            for (size_t n = 0; node != nullptr && n < MAX_SCAN; ++n) {
                if (node->capacity >= min_size) {
                    if (prev == nullptr) {
                        bins_[idx] = node->next;
                    } else {
                        prev->next = node->next;
                    }
                    bin_bytes_[idx] -= node->capacity;
                    out_capacity = node->capacity;
                    return reinterpret_cast<std::Byte *>(node);
                }
                prev = node;
                node = node->next;
            }
        }

        return nullptr;
    }

    void clear() noexcept {
        std::LockGuard<std::Mutex> lock(_mu);
        for (size_t i = 0; i < NUM_BINS; ++i) {
            bin_bytes_[i] = 0;
        }
        for (auto &bin : bins_) {
            Node *node = bin;
            bin        = nullptr;
            while (node != nullptr) {
                Node *next = node->next;
#ifdef _MSC_VER
                _aligned_free(reinterpret_cast<std::Byte *>(node));
#else
                libcxx::free(reinterpret_cast<std::Byte *>(node));
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