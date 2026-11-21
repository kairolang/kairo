/* --- The Kairo Project ---------------------------------- Lib/rt/heap.h --- */
/*
 *   The runtime heap's out-of-line entry points (rt/heap.c), shared by
 *   System (Lib/builtin/alloc_raw.k, through rt/alloc.h) and the weak
 *   kairo_global_* definitions (rt/global_alloc.c), so a block either one
 *   made is one the other can free, resize and reallocate.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#ifndef KAIRO_RT_HEAP_H
#define KAIRO_RT_HEAP_H

#include <stddef.h>

#ifndef KAIRO_RT_NOEXCEPT
#ifdef __cplusplus
#define KAIRO_RT_NOEXCEPT noexcept
#else
#define KAIRO_RT_NOEXCEPT
#endif
#endif

#ifdef __cplusplus
#define KAIRO_RT_HEAP_BOOL bool
extern "C" {
#else
#define KAIRO_RT_HEAP_BOOL _Bool
#endif

/* The Resizer and Reallocator halves of System, for every size: resize
 * never moves the block (false: nothing changed); realloc may (null:
 * nothing changed). */
KAIRO_RT_HEAP_BOOL kairo_rt_heap_resize(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;
unsigned char *kairo_rt_heap_realloc(unsigned char *ptr, size_t old_size, size_t new_size, size_t align) KAIRO_RT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif /* KAIRO_RT_HEAP_H */
