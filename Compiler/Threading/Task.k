/// --- The Kairo Project ----------------------------- Threading/Task.k --- ///
///
///   Task: a move-only unit of pool work, tagged with a group.
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
ffi "c++" import "utility"

/// Represents a unit of work executed by the thread pool.
///
/// A `Task` encapsulates a small callable (`SmallFunction<64>`) and a
/// numeric group identifier. Tasks are copy-disabled and move-only to
/// preserve function storage locality and prevent accidental
/// duplication across queues.
///
/// See enqueue, PartitionQueue.
pub class Task {
    /// The callable function to execute.
    ///
    /// Numeric group ID for synchronization tracking.
    pub var _fn:    kairo::SmallFunction<64>
    pub var _group: u8                       = 0

    /// Default constructor initializes an empty task.
    fn Task(self) { }

    /// Move constructor transfers ownership of the callable and
    /// group ID.
    ///
    /// ### Parameters
    /// - `other`: Source task to move from. (mref! is a c++ && rvalue)
    @move fn Task(self, other: Self) {
        self._fn    = kairo::SmallFunction<64>(cxx::std::move(other._fn))
        self._group = other._group
    }

    /// Move assignment operator transfers ownership, guarding
    /// against self-assignment.
    ///
    /// ### Parameters
    /// - `other`: Source task to move from. (mref! is a c++ && rvalue)
}
