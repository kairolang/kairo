/// --- The Kairo Project ------------------- Lib/builtin/coro/suspend.k --- ///
///
///   Suspend: the awaiter every suspension point uses.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

/// The awaiter every suspension point uses: always suspends, does nothing on
/// suspend or resume. clang requires the awaiter of `final_suspend` to be
/// non-throwing in all three calls, so all three are marked.
pub class Suspend {
    @no_unwind pub inline fn await_ready(self) -> bool { return false }
    @no_unwind pub inline fn <H> await_suspend(self, h: H) { }
    @no_unwind pub inline fn await_resume(self) { }
}
