/// --- The Kairo Project -------------------- Lib/builtin/coro/future.k --- ///
///
///   The Future lang item, the handle that `spawn f()` returns. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The result type of `spawn f()`: a handle to a value of type `T` that is still being computed.
///
/// Layout only for now: `state` points at the task's shared state.
pub struct <T> Future  { var state: *void }
