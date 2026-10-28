/* --- The Kairo Project ------------------------ Lib/rt/fmt_alloc.c --- */
/*
 *   The heap FmtBuf (Lib/builtin/fmt/fmt_buf.k) draws on, and the exact
 *   path's spill for a long fixed-precision request.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/fmt.h"

#include <stdlib.h>

unsigned char *kairo_rt_fmt_alloc(size_t n)                     { return (unsigned char *)malloc(n); }
unsigned char *kairo_rt_fmt_realloc(unsigned char *p, size_t n) { return (unsigned char *)realloc(p, n); }
void           kairo_rt_fmt_free(unsigned char *p)              { free(p); }
