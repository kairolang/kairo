/* --- The Kairo Project ----------------------------- Lib/rt/crash.c --- */
/*
 *   See rt/crash.h. write(2) straight to fd 2, looping on short writes the
 *   way rt/unwrap.c does, so nothing buffered can lose the message when
 *   abort() ends the process.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
#include "rt/crash.h"

#include <stdlib.h>

#ifdef _WIN32
#include <io.h>
#define kairo_rt_crash_write_ _write
#else
#include <unistd.h>
#define kairo_rt_crash_write_ write
#endif

static void kairo_rt_crash_put_(const unsigned char *p, size_t len) {
    size_t off = 0;
    while (off < len) {
        size_t chunk = len - off;
        if (chunk > 0x7FFFF000u) { chunk = 0x7FFFF000u; }
        long w = (long)kairo_rt_crash_write_(2, p + off, (unsigned)chunk);
        if (w <= 0) { return; }   /* nothing left to report it on */
        off += (size_t)w;
    }
}

void kairo_rt_crash(const unsigned char *msg, size_t len) {
    if (len > 0) {
        kairo_rt_crash_put_(msg, len);
        kairo_rt_crash_put_((const unsigned char *)"\n", 1);
    }
    abort();
}
