#pragma once

#include <include/core.hh>

#include "Types.hh"

namespace kairo {
constexpr bool   PRE_TOUCH  = false;
constexpr size_t SIMD_WIDTH = 64;

inline size_t align_up(size_t v, size_t align) noexcept {
    return (v + align - 1) & ~(align - 1);
}

class GlobalRecycler {
    struct Node {
        Node      *next;
        std::Byte *block;
        size_t     size;
    };

    std::Atomic<Node *> head{nullptr};

  public:
    static GlobalRecycler &instance() noexcept {
        static GlobalRecycler inst;
        return inst;
    }

    void push(std::Byte *block, size_t size) noexcept {
        auto *n = std::create<Node>(
            head.load(std::MemoryOrder::relaxed), block, size);

        while (!head.compare_exchange_weak(
            n->next, n, std::MemoryOrder::release, std::MemoryOrder::relaxed)) {
            ;
        }
    }

    static void shutdown_allocator_runtime() {
        GlobalRecycler::instance().clear();
    }

    std::Byte *pop(size_t min_size) noexcept {
        Node *n = head.load(std::MemoryOrder::acquire);

        while (n) {
            if (head.compare_exchange_weak(
                    n, n->next,
                    std::MemoryOrder::acq_rel,
                    std::MemoryOrder::relaxed)) {

                std::Byte *blk = nullptr;

                if (n->size >= min_size) {
                    blk = n->block;
                } else {
                    libcxx::free(n->block);
                }

                libcxx::free(n);
                return blk;
            }
        }
        return nullptr;
    }

    void clear() noexcept {
        Node *n = head.exchange(nullptr, std::MemoryOrder::acq_rel);

        while (n != nullptr) {
            Node *next = n->next;

            libcxx::free(n->block);
            libcxx::free(n);

            n = next;
        }
    }
};
}  // namespace kairo