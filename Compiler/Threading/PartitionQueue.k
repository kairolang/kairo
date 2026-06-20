/// --- The Kairo Project ------------------- Threading/PartitionQueue.k --- ///
///
///   Defines the `PartitionQueue` class, a lock-free circular buffer for
///   per-thread task storage in the thread pool.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE.txt
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/SmallFunction.hh";
ffi "c++" import "Native/Types.hh";

import Threading::Task::*;
import Threading::CacheLines::*;

///
/// \class PartitionQueue
///
/// \brief Lock-free circular buffer for per-thread task storage.
///
/// \details
/// Implements a cache-aligned ring buffer with atomic sequence counters for
///     enqueue/dequeue coordination. Each queue supports concurrent
///     producers and consumers through relaxed atomic operations.
///     `push()` and `pop()` follow a bounded MPMC pattern using
///     `compare_exchange_weak` for contention resolution, while `steal()`
///     allows cross-queue task acquisition.
///
/// \warning
///   - Capacity must be a power of two.
///   - Each cell maintains a monotonic sequence to prevent ABA hazards.
///
/// \see Task, ThreadPool
///
class PartitionQueue {
    struct Cell;

    priv var _buf:  vec::<Cell>;
    priv var _mask: u64 = 0;
    priv var _cap:  u64 = 0;

    priv var _enqueue_pos: std::Atomic::<u64> = std::Atomic::<u64>(0);
    priv var _dequeue_pos: std::Atomic::<u64> = std::Atomic::<u64>(0);

    inline "c++" {
        static constexpr size_t DEFAULT_QUEUE_SIZE = 1 << 14;
    }

    ///
    /// \struct ThreadPool::PartitionQueue::Cell
    ///
    /// \brief Cache-aligned storage cell for a single task entry in the
    ///        partitioned queue.
    ///
    /// \details
    /// The `Cell` struct represents one slot in the lock-free circular
    ///     buffer backing each `PartitionQueue`. Each cell maintains an
    ///     atomic sequence counter and a stored `Task`, ensuring proper
    ///     synchronization between producers and consumers without locks.
    ///
    /// The `seq` field acts as a ticket system:
    ///     - When `seq == position`, the cell is available for enqueue.
    ///     - When `seq == position + 1`, the cell contains a valid task for
    ///       dequeue.
    ///     - When `seq` advances beyond the current window, the cell is
    ///       recycled for reuse.
    ///
    /// The `val` field holds the actual task to be executed.
    ///
    /// Each cell is cache-line aligned to prevent false sharing between adjacent
    ///     queue entries during concurrent access by multiple threads.
    ///
    /// ### Constructors and Operators
    ///     - Default constructor: Initializes an empty cell with `seq = 0`.
    ///     - Move constructor: Transfers ownership of the stored task and
    ///       sequence counter in a relaxed, lock-free manner for relocation
    ///       of queue buffers.
    ///     - Move assignment: Same as move construction, but guards self-
    ///       assignment and preserves sequence ordering.
    ///     - Copy operations: Explicitly deleted to enforce unique cell
    ///       ownership and prevent accidental data duplication.
    ///
    /// ### Memory Ordering
    ///     - Sequence loads and stores use `memory_order::relaxed` since
    ///       ordering guarantees are enforced externally by producer/
    ///       consumer operations in `push()` and `pop()`.
    ///
    /// \warning
    ///     - Instances must not be copied.
    ///     - Sequence counter integrity must be maintained; modifying `seq`
    ///       directly outside queue operations can lead to corruption.
    ///     - Cache-line alignment (`CACHE_LINE`) is mandatory for avoiding
    ///       performance degradation due to false sharing.
    ///
    /// \see PartitionQueue, Task, ThreadPool
    ///
    inline "c++" {
        struct alignas(CACHE_LINE) Cell {
            std::Atomic<u64> seq {0};
            Task        val;

            Cell() = default;

            Cell(Cell&& other) noexcept {
                auto seq_val = other.seq.load(libcxx::memory_order::relaxed);
                seq.store(seq_val, libcxx::memory_order::relaxed);

                val = std::Memory::move(other.val);
            }

            Cell &operator=(Cell&& other) noexcept {
                if (this != &other) {
                    auto seq_val = other.seq.load(libcxx::memory_order::relaxed);
                    seq.store(seq_val, libcxx::memory_order::relaxed);

                    val = std::Memory::move(other.val);
                }

                return *this;
            }

            Cell           (const Cell&) = delete;
            Cell &operator=(const Cell&) = delete;
        };
    }

    ///
    /// \brief Constructs a partitioned queue with the specified capacity.
    ///
    /// \param cap_req Desired capacity (rounded up to next power of two).
    ///
    /// \details
    /// Allocates and initializes the internal circular buffer to the
    ///     smallest power-of-two size greater than or equal to `cap_req`.
    ///     Each cell's sequence counter is initialized to its index to
    ///     establish the initial empty state.
    ///
    /// \warning Capacity must be a power of two for correct operation.
    ///
    /// \see push, pop, steal
    ///
    fn PartitionQueue(self, cap_req: usize = DEFAULT_QUEUE_SIZE) {
        var c: usize = 1;

        while c < cap_req {
            c <<= 1;
        }

        self._cap  = static_cast::<u64>(c);
        self._mask = static_cast::<u64>(c - 1);
        self._buf.resize(c);

        for i in range::<usize>(0, c) {
            self._buf[i].seq.store(
                static_cast::<u64>(i),
                std::MemoryOrder::relaxed
            );
        }
    }

    ///
    /// \brief Inserts a task into the queue.
    ///
    /// \param v Task to enqueue (moved).
    /// \return `true` if the task was successfully enqueued, otherwise `false` if full.
    ///
    inline fn push(self, v: ref!(Task)) -> bool {
        var pos = self._enqueue_pos.load(std::MemoryOrder::relaxed);

        while true {
            var idx  = static_cast::<usize>(pos & self._mask);
            var cell = &self._buf[idx];
            var seq  = cell->seq.load(std::MemoryOrder::acquire);
            var dif  = static_cast::<i64>(seq) - static_cast::<i64>(pos);

            if dif == 0 {
                if self._enqueue_pos.compare_exchange_weak(
                    pos, pos + 1,
                    std::MemoryOrder::acq_rel,
                    std::MemoryOrder::relaxed) {

                    cell->val = std::Memory::move(v);
                    cell->seq.store(pos + 1, std::MemoryOrder::release);
                    return true;
                }
            } else if dif < 0 {
                return false;
            } else {
                _thread_pause();
            }

            pos = self._enqueue_pos.load(std::MemoryOrder::relaxed);
        }
    }

    ///
    /// \brief Removes a task from the queue.
    ///
    /// \param out Pointer to receive dequeued task.
    /// \return `true` if successful, `false` if queue is empty.
    ///
    inline fn pop(self, out: *Task) -> bool {
        var pos = self._dequeue_pos.load(std::MemoryOrder::relaxed);

        while true {
            var idx  = static_cast::<usize>(pos & self._mask);
            var cell = &self._buf[idx];
            var seq  = cell->seq.load(std::MemoryOrder::acquire);
            var dif  = static_cast::<i64>(seq) - static_cast::<i64>(pos + 1);

            if dif == 0 {
                if self._dequeue_pos.compare_exchange_weak(pos, pos + 1,
                    std::MemoryOrder::release, std::MemoryOrder::relaxed)
                {
                    (*out) = std::Memory::move(cell->val);
                    cell->seq.store(pos + self._cap, std::MemoryOrder::release);
                    return true;
                }
            } else if dif < 0 {
                return false;
            } else {
                _thread_pause();
                pos = self._dequeue_pos.load(std::MemoryOrder::relaxed);
            }
        }
    }

    ///
    /// \brief Attempts to steal a task from the queue.
    ///
    /// \param out Pointer to receive stolen task.
    /// \return `true` if a task was stolen, otherwise `false`.
    ///
    inline fn steal(self, out: *Task) -> bool {
        return self.pop(out);
    }
}