/// --- The Kairo Project ------------------- Lib/builtin/errors/crash.k --- ///
///
///   The crash path (PANIC.md §2.4, §2.8): the UnwrapFailed lang item and
///   crash_with, both over rt/crash.c. Not a panic: no `try` catches
///   either. The `crash!` macro that calls crash_with is in module.k: a
///   macro reaches the prelude only from the root file itself (the
///   preprocessor does not follow `pub import` re-exports).
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import string::*

ffi "c" import "rt/crash.h"

/// Crashes with a compiler-built message; the `UnwrapFailed` lang item.
///
/// Called for `unwrap!` on null, a checked `as` into a closed enum that misses, a script global
/// read before its line ran, and an asserting downcast `p as *D` on the wrong dynamic type.
/// `msg[0..len)` is a literal the lowering built whole (the expression as written and its
/// file:line:col), so nothing is formatted at crash time. The runtime writes it and a newline to
/// stderr and aborts. `-> !` makes the failing arm `Never`. Not a panic: no `try` catches it and
/// it is in no panic set.
///
/// \param msg  Pointer to `len` bytes of message.
/// \safety `msg` must be valid for reads of `len` bytes (a null `msg` is an empty message).
pub fn unwrap_failed(msg: *const u8, len: usize) -> ! {
    unsafe { kairo_rt_crash(msg as unsafe *const u8, len) }
}

/// Writes `msg` and a newline to stderr (nothing when `msg` is empty), then aborts. This is what
/// `crash!` calls.
///
/// A runtime `string` is fine: its data pointer and length are read once and handed to the
/// runtime, which writes at most `KAIRO_RT_CRASH_MAX` (4096) bytes of them and runs no `string`
/// method. A literal costs no allocation. `-> !`, so a call ends its path for the flow checks.
/// Not a panic.
///
/// \see crash!
pub fn crash_with(msg: string = "") -> ! {
    unsafe { kairo_rt_crash(msg.as_ptr() as unsafe *const u8, msg.length()) }
}
