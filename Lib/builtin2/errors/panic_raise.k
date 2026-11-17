/// --- The Kairo Project ------------- Lib/builtin/errors/panic_raise.k --- ///
///
///   The PanicRaise lang item, PanicLowering's raise entry. Layout only.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// PanicLowering's raise entry point (the `PanicRaise` lang item).
///
/// Compiler-facing; user code does not name it. Layout only: `payload` is an opaque pointer.
pub struct PanicRaise { var payload: *void }
