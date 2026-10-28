/* --- The Kairo Project ----------------------------- Lib/rt/crash.h --- */
/*
 *   The one runtime entry of the crash family (PANIC.md §2.4, §2.8):
 *   `crash!()`, `unwrap!` on null, a checked `as` into a closed enum that
 *   misses, a script global read before its line ran, and the asserting
 *   downcast `p as *D` on the wrong dynamic type. Not a panic: nothing
 *   catches it and it is in no panic set.
 *
 *   It runs on a program that just proved itself wrong, so it assumes the
 *   worst -- frames mangled, the heap corrupt, a lock held -- and does only
 *   what a signal handler may: no stdio, no allocation, no locks, no Kairo
 *   code, nothing but async-signal-safe calls. The message arrives fully
 *   formed (the compiler bakes the text and its file:line:col into a
 *   literal; `crash!(s)` passes a string's data pointer and length, read
 *   once), so nothing is formatted here.
 *
 *     1. A re-entry guard: a crash while crashing (another thread, or a
 *        fault inside this function) skips the message and terminates.
 *     2. msg[0..min(len, KAIRO_RT_CRASH_MAX)) and a newline, ONE write(2)
 *        to fd 2 (nothing at all when len is 0), retried only on EINTR or
 *        a short write. A null msg is an empty one.
 *     3. SIGABRT back to SIG_DFL and unblocked, so no user handler runs on
 *        the broken state, then abort(): the process dies of SIGABRT.
 *     4. __builtin_trap() if abort() ever returns.
 *
 *   Per target: POSIX (Linux, macOS, BSD) all four steps. Windows: _write,
 *   signal(SIGABRT, SIG_DFL) (no mask to clear), abort(). wasm/WASI: the
 *   write, no signals, abort() (which is a trap there).
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_CRASH_H
#define KAIRO_RT_CRASH_H

#include <stddef.h>

/* The longest message written, in bytes; the rest is dropped. A corrupt
 * length must not turn the crash into a scan through memory. */
#define KAIRO_RT_CRASH_MAX 4096

#ifdef __cplusplus
extern "C" {
#endif

/* See above. Never returns. */
__attribute__((noreturn)) void kairo_rt_crash(const unsigned char *msg, size_t len);
/* `__builtin_crash`: the same message, then _Exit(code). */
__attribute__((noreturn)) void kairo_rt_crash_exit(const unsigned char *msg, size_t len, int code);
/* `__builtin_signal`: the same message, then raise(sig) at its default action. */
__attribute__((noreturn)) void kairo_rt_signal(const unsigned char *msg, size_t len, int sig);

#ifdef __cplusplus
}
#endif

#endif
