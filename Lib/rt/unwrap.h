/* --- The Kairo Project ---------------------------- Lib/rt/unwrap.h --- */
/*
 *   The C behind `unwrap!(x)` on null (NULLABLE.md 2.6): the message, then
 *   abort(). Not a panic: nothing catches it, so the process ends with
 *   SIGABRT, as C++'s std::abort does. The message is built at compile
 *   time ("unwrap!(x) on null at file.k:12:9" and a newline), so this file
 *   formats nothing and imports no variadic.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_UNWRAP_H
#define KAIRO_RT_UNWRAP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* msg[0..len) to stderr, then abort(). Never returns. */
__attribute__((noreturn)) void kairo_rt_unwrap_failed(const unsigned char *msg, size_t len);

#ifdef __cplusplus
}
#endif

#endif
