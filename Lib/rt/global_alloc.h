/* --- The Kairo Project ---------------------- Lib/rt/global_alloc.h --- */
/*
 *   The program's global allocator, as five C symbols. The builtin's
 *   Global (Lib/builtin/base/alloc.k) calls them; which allocator answers
 *   is decided when the program links:
 *
 *     - the runtime defines each WEAKLY, as System: malloc / free /
 *       realloc / calloc, and the aligned entry points past
 *       2 * sizeof(void *) (Lib/rt/global_alloc.c);
 *     - the one file that writes `@set_global_allocator(A)` defines each
 *       STRONGLY, as a forwarder to A's static function of the same name
 *       (the compiler writes them; EmitIR::_global_allocator).
 *
 *   A strong definition beats a weak one, so the program gets A without a
 *   single other file knowing; two strong definitions are a duplicate
 *   symbol, which the driver reports naming both objects.
 *
 *   ABI. The names, the argument order and the types below are fixed:
 *   objects built by different compiler versions must agree on them, and
 *   so must a C or C++ object that defines them by hand to supply the
 *   allocator. The contract is alloc.k's Allocator one: align is a power
 *   of two and size is never 0 (the front end returns early on both);
 *   free gets the size and align the block was made with; failure is a
 *   null return, never an abort; a failed resize or realloc leaves the
 *   block untouched; every function is thread-safe. resize never moves
 *   the block (false: nothing changed); realloc may (null: nothing
 *   changed).
 *
 *   Without LTO a Global call is one direct call to these; with LTO the
 *   forwarder and, where A's functions are inline, A itself inline into
 *   the caller.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_GLOBAL_ALLOC_H
#define KAIRO_RT_GLOBAL_ALLOC_H

#include <stddef.h>

#ifndef KAIRO_RT_NOEXCEPT
/* Every Kairo function is noexcept, the forwarders included; a C++
 * declaration must say so too, or the two conflict in a TU that has both,
 * and a call from a Kairo function into one that is not gets a landing pad
 * that calls std::terminate. */
#ifdef __cplusplus
#define KAIRO_RT_NOEXCEPT noexcept
#else
#define KAIRO_RT_NOEXCEPT
#endif
#endif

#ifdef __cplusplus
#define KAIRO_RT_GLOBAL_BOOL bool
extern "C" {
#else
#define KAIRO_RT_GLOBAL_BOOL _Bool
#endif

unsigned char       *kairo_global_alloc(size_t size, size_t align) KAIRO_RT_NOEXCEPT;
void                 kairo_global_free(unsigned char *ptr, size_t size, size_t align) KAIRO_RT_NOEXCEPT;
KAIRO_RT_GLOBAL_BOOL kairo_global_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;
unsigned char       *kairo_global_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;
unsigned char       *kairo_global_alloc_zeroed(size_t size, size_t align) KAIRO_RT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif /* KAIRO_RT_GLOBAL_ALLOC_H */
