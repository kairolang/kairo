/* --- The Kairo Project ---------------------------- Lib/rt/unwrap.c --- */
/*
 *   See rt/unwrap.h. write(2) straight to fd 2, looping on short writes the
 *   way Lib/std/io.k does, so nothing buffered can lose the message when
 *   abort() ends the process.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/unwrap.h"

#include <stdlib.h>

#ifdef _WIN32
#include <io.h>
#define kairo_rt_write_ _write
#else
#include <unistd.h>
#define kairo_rt_write_ write
#endif

void kairo_rt_unwrap_failed(const unsigned char *msg, size_t len) {
    size_t off = 0;
    while (off < len) {
        size_t chunk = len - off;
        if (chunk > 0x7FFFF000u) { chunk = 0x7FFFF000u; }
        long w = (long)kairo_rt_write_(2, msg + off, (unsigned)chunk);
        if (w <= 0) { break; }   /* nothing left to report it on */
        off += (size_t)w;
    }
    abort();
}
