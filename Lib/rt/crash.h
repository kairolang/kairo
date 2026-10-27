/* --- The Kairo Project ----------------------------- Lib/rt/crash.h --- */
/*
 *   The C behind `crash!()` (PANIC.md §2.4): the message, if any, then
 *   abort(). Not a panic: nothing catches it and it is in no panic set, so
 *   the process ends with SIGABRT. The macro and the `-> !` function it
 *   calls are Kairo, in Lib/builtin/module.k; this file only writes bytes
 *   and stops, so it formats nothing and imports no variadic.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_CRASH_H
#define KAIRO_RT_CRASH_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* msg[0..len) and a newline to stderr (nothing at all when len is 0),
 * then abort(). Never returns. */
__attribute__((noreturn)) void kairo_rt_crash(const unsigned char *msg, size_t len);

#ifdef __cplusplus
}
#endif

#endif
