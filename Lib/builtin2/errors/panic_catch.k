/// --- The Kairo Project ------------- Lib/builtin/errors/panic_catch.k --- ///
///
///   The PanicCatch lang item, PanicLowering's catch entry. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// PanicLowering's catch entry point (the `PanicCatch` lang item).
///
/// Compiler-facing; user code does not name it. Layout only: `payload` is an opaque pointer.
pub struct PanicCatch { var payload: *void }
