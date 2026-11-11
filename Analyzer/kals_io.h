/* --- The Kairo Project ---------------------------- Analyzer/kals_io.h --- *
 *
 *   The three things kals needs from the OS that are not in Lib/std yet and
 *   differ per platform: binary stdio, "is there input within N ms", and a
 *   raw read. One header so the C preprocessor picks the platform (an ffi
 *   import cannot be chosen per target from Kairo).
 *
 *   WHY A TIMED WAIT AND NOT A READER THREAD: the server is one loop that
 *   interleaves requests with worker processes finishing. Waiting on stdin
 *   with a timeout is the whole of what that needs; a thread would add a
 *   queue, a lock and a shutdown order for the same effect.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 *   Copyright (c) 2026 Dhruvan Kartik
 *
 * ------------------------------------------------------------------------ */

#pragma once

#include <stdio.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <poll.h>
#include <unistd.h>
#endif

/* LSP frames are byte-counted. Text mode on Windows rewrites \n as \r\n on
 * the way out and eats \r on the way in, which breaks every Content-Length. */
static inline void kals_stdio_binary(void) {
#ifdef _WIN32
    (void)_setmode(0, _O_BINARY);
    (void)_setmode(1, _O_BINARY);
#endif
}

/* 1: stdin has bytes (or is at EOF, which a read then reports); 0: nothing
 * within `ms`; -1: error. */
static inline int kals_stdin_wait(int ms) {
#ifdef _WIN32
    HANDLE h = GetStdHandle(STD_INPUT_HANDLE);
    DWORD avail = 0;
    if (GetFileType(h) == FILE_TYPE_PIPE) {
        /* An editor talks over a pipe, and a pipe handle is not waitable:
         * poll it. 10 ms steps keep the latency below a keystroke. */
        int waited = 0;
        for (;;) {
            if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
                return 1; /* broken pipe: let the read see EOF */
            }
            if (avail > 0) {
                return 1;
            }
            if (waited >= ms) {
                return 0;
            }
            Sleep(10);
            waited += 10;
        }
    }
    return WaitForSingleObject(h, (DWORD)ms) == WAIT_OBJECT_0 ? 1 : 0;
#else
    struct pollfd p;
    p.fd = 0;
    p.events = POLLIN;
    p.revents = 0;
    int r = poll(&p, 1, ms);
    if (r < 0) {
        return -1;
    }
    return r > 0 ? 1 : 0;
#endif
}

/* Bytes read (0 at EOF, negative on error). Never blocks past the first byte
 * available: it returns what the pipe holds, up to `cap`. */
static inline long long kals_stdin_read(unsigned char *buf, unsigned long long cap) {
#ifdef _WIN32
    return (long long)_read(0, buf, (unsigned int)cap);
#else
    return (long long)read(0, buf, (size_t)cap);
#endif
}

static inline long long kals_stdout_write(const unsigned char *buf, unsigned long long n) {
#ifdef _WIN32
    return (long long)_write(1, buf, (unsigned int)n);
#else
    return (long long)write(1, buf, (size_t)n);
#endif
}

static inline void kals_sleep_ms(int ms) {
#ifdef _WIN32
    Sleep((DWORD)ms);
#else
    (void)poll(NULL, 0, ms);
#endif
}
