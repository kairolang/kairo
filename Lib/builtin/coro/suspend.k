/// --- The Kairo Project ------------------- Lib/builtin/coro/suspend.k --- ///
///
///   Suspend: the awaiter every suspension point uses.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The awaiter every suspension point uses: it always suspends and does nothing on suspend or
/// resume.
///
/// clang requires the awaiter of `final_suspend` to be non-throwing in all three calls, so all
/// three are marked `@no_unwind`.
pub class Suspend {
    /// Returns false: the awaiter always suspends.
    @no_unwind pub inline fn await_ready(self) -> bool { return false }
    /// Does nothing on suspend; the handle `h` is ignored.
    @no_unwind pub inline fn <H> await_suspend(self, h: H) { }
    /// Does nothing on resume.
    @no_unwind pub inline fn await_resume(self) { }
}
