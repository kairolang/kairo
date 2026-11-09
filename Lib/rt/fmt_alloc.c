/* --- The Kairo Project ------------------------ Lib/rt/fmt_alloc.c --- */
/*
 *   The exact path's spill for a long fixed-precision request
 *   (fmt_layout.c). FmtBuf itself allocates through Lib/builtin/base/alloc.k
 *   now, the allocator the string it finishes frees with.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt.h"

#include <stdlib.h>

unsigned char *kairo_rt_fmt_alloc(size_t n)                     { return (unsigned char *)malloc(n); }
unsigned char *kairo_rt_fmt_realloc(unsigned char *p, size_t n) { return (unsigned char *)realloc(p, n); }
void           kairo_rt_fmt_free(unsigned char *p)              { free(p); }
