/// --- The Kairo Project ------------------- Threading/PartitionQueue.k --- ///
///
///   PartitionQueue: the lock-free circular task buffer of one pool thread.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c++" import "Native/SmallFunction.hh"
ffi "c++" import "Native/Types.hh"
ffi "c++" import "Native/KThread.hh" // SeqCell
ffi "c++" import "vector"
ffi "c++" import "utility"

import Threading::CacheLines::CACHE_LINE
import Threading::Task::Task

/// Default ring capacity, in tasks, for a PartitionQueue and so for each of
/// a ThreadPool's queues. Module scope: Kairo has no class-level constant.
pub
const DEFAULT_QUEUE_SIZE: usize = 1 << 14

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
pub class PartitionQueue {
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
    /// The cell is Native/KThread.hh's SeqCell: Kairo has no `alignas`, and
    /// its move has to relax through the atomic counter.
    type Cell = kairo::SeqCell<Task, CACHE_LINE>

    priv var _buf:  cxx::std::vector<Self::Cell>
    priv var _mask: u64                          = 0
    priv var _cap:  u64                          = 0

    priv var _enqueue_pos: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)
    priv var _dequeue_pos: kairo::std::Atomic<u64> = kairo::std::Atomic<u64>(0)

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
    fn PartitionQueue(self) {
        var cap_req: usize = DEFAULT_QUEUE_SIZE
        var c:       usize = 1

        while c < cap_req {
            c <<= 1
        }

        self._cap  = (c as u64)
        self._mask = ((c - 1) as u64)
        self._buf.resize(c)

        for i in (0 as usize)..c {
            self._buf[i].seq.store(i as u64, kairo::std::MemoryOrder::relaxed)
        }
    }

    fn PartitionQueue(self, cap_req: usize) {
        var c: usize = 1

        while c < cap_req {
            c <<= 1
        }

        self._cap  = (c as u64)
        self._mask = ((c - 1) as u64)
        self._buf.resize(c)

        for i in (0 as usize)..c {
            self._buf[i].seq.store(i as u64, kairo::std::MemoryOrder::relaxed)
        }
    }

    ///
    /// \brief Inserts a task into the queue.
    ///
    /// \param v Task to enqueue (moved).
    /// \return `true` if the task was successfully enqueued, otherwise `false` if full.
    ///
    inline fn push(self, @inout v: Task) -> bool {
        var pos = self._enqueue_pos.load(kairo::std::MemoryOrder::relaxed)

        while true {
            var idx   = ((pos & self._mask) as usize)
            var *cell = &self._buf[idx]
            var seq   = cell->seq.load(kairo::std::MemoryOrder::acquire)
            var dif   = (seq as i64) - (pos as i64)

            if dif == 0 {
                if self._enqueue_pos.compare_exchange_weak(
                    &pos,
                    pos + 1,
                    kairo::std::MemoryOrder::acq_rel,
                    kairo::std::MemoryOrder::relaxed,
                ) {
                    cell->val = cxx::std::move(v)
                    cell->seq.store(pos + 1, kairo::std::MemoryOrder::release)
                    return true
                }
            } else if dif < 0 {
                return false
            } else {
                kairo::thread_pause()
            }

            pos = self._enqueue_pos.load(kairo::std::MemoryOrder::relaxed)
        }
    }

    ///
    /// \brief Removes a task from the queue.
    ///
    /// \param out Pointer to receive dequeued task.
    /// \return `true` if successful, `false` if queue is empty.
    ///
    inline fn pop(self, out: *Task) -> bool {
        var pos = self._dequeue_pos.load(kairo::std::MemoryOrder::relaxed)

        while true {
            var idx   = ((pos & self._mask) as usize)
            var *cell = &self._buf[idx]
            var seq   = cell->seq.load(kairo::std::MemoryOrder::acquire)
            var dif   = (seq as i64) - ((pos + 1) as i64)

            if dif == 0 {
                if self._dequeue_pos.compare_exchange_weak(
                    &pos,
                    pos + 1,
                    kairo::std::MemoryOrder::release,
                    kairo::std::MemoryOrder::relaxed,
                ) {
                    *out = cxx::std::move(cell->val)
                    cell->seq.store(
                        pos + self._cap,
                        kairo::std::MemoryOrder::release,
                    )

                    return true
                }
            } else if dif < 0 {
                return false
            } else {
                kairo::thread_pause()
                pos = self._dequeue_pos.load(kairo::std::MemoryOrder::relaxed)
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
        return self.pop(out)
    }
}
