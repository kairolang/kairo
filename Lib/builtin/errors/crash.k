/// --- The Kairo Project ------------------- Lib/builtin/errors/crash.k --- ///
///
///   The crash path (PANIC.md §2.4, §2.8): the UnwrapFailed lang item and
///   crash_with, both over rt/crash.c. Not a panic: no `try` catches
///   either. The `crash!` macro that calls crash_with is in module.k: a
///   macro reaches the prelude only from the root file itself (the
///   preprocessor does not follow `pub import` re-exports).
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import string::*

ffi "c" import "rt/crash.h"

/// The compiler's crash entry (the UnwrapFailed lang item): `unwrap!` on
/// null (NULLABLE.md 2.6), a checked `as` into a closed enum that misses,
/// a script global read before its line ran, and the asserting downcast
/// `p as *D` on the wrong dynamic type. `msg[0..len)` is a literal the
/// lowering built whole -- the expression as written and its
/// file:line:col -- so nothing is formatted at crash time; rt/crash.c
/// writes it and a newline to stderr and aborts (PANIC.md §2.8, "the crash
/// path"). `-> !` makes the failing arm `Never`. Not a panic: no `try`
/// catches it and it is in no panic set.
pub fn unwrap_failed(msg: *const u8, len: usize) -> ! {
    unsafe { kairo_rt_crash(msg as unsafe *const u8, len) }
}

/// What `crash!` calls: `msg` and a newline to stderr (nothing when it is
/// empty), then abort. `-> !`, so a `crash!()` ends its path for the flow
/// checks like any other call that never returns. A runtime `string` is
/// fine: its data pointer and length are read once, here, and handed to
/// rt/crash.c, which writes at most KAIRO_RT_CRASH_MAX bytes of them and
/// touches nothing else (no method of `string` runs on a program that is
/// crashing). A literal costs no allocation: it is a borrowed view.
pub fn crash_with(msg: string = "") -> ! {
    unsafe { kairo_rt_crash(msg.as_ptr() as unsafe *const u8, msg.length()) }
}
