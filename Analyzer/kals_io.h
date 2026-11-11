/* --- The Kairo Project ---------------------------- Analyzer/kals_io.h --- *
 *
 *   What kals needs from the OS that is not in Lib/std yet and differs per
 *   platform: binary stdio, "is there input within N ms", a raw read, and a
 *   child on pipes (the persistent syntax worker) whose answers wake the
 *   same wait. One header so the C preprocessor picks the platform (an ffi
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
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
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

/* --- a child on pipes: the persistent syntax worker (section 11, 2a) -------
 *
 * llvm::sys::ExecuteNoWait redirects to files only; the syntax worker is fed
 * buffers on its stdin and answers on its stdout, so it needs pipes, and the
 * server's loop needs the answer pipe in the same wait as stdin, so an
 * answer wakes it the moment it is written rather than on the next idle
 * tick. */

/* Starts the program \p argv names ('\n'-separated words in \p argv, \p n
 * bytes; the first is the executable path) with its stdin and stdout on
 * pipes and its stderr inherited. *to_child is where requests are written,
 * *from_child (non-blocking) where answers are read. The pid, or -1 when no
 * child was started (the caller falls back to a process per pass). */
static inline long long kals_child_spawn(const unsigned char *argv, unsigned long long n, int *to_child,
                                         int *from_child) {
#ifdef _WIN32
    /* TODO(WINDOWS): CreatePipe + CreateProcess, and the read end in
     * kals_poll2 (a pipe handle is not waitable: PeekNamedPipe as in
     * kals_stdin_wait). Until then the server uses a process per pass. */
    (void)argv;
    (void)n;
    *to_child   = -1;
    *from_child = -1;
    return -1;
#else
    /* A write to a child that died must be an error the caller sees, not a
     * signal that takes the editor's connection with it. */
    signal(SIGPIPE, SIG_IGN);

    char  *words = (char *)malloc(n + 1);
    char **av    = (char **)malloc(sizeof(char *) * (n + 2));
    if (words == NULL || av == NULL) {
        free(words);
        free(av);
        return -1;
    }
    memcpy(words, argv, n);
    words[n] = 0;
    int    ac = 0;
    char  *s  = words;
    av[ac++]  = s;
    for (unsigned long long i = 0; i < n; ++i) {
        if (words[i] == '\n') {
            words[i] = 0;
            av[ac++] = &words[i + 1];
        }
    }
    av[ac] = NULL;

    int in_p[2], out_p[2];
    if (pipe(in_p) != 0) {
        free(words);
        free(av);
        return -1;
    }
    if (pipe(out_p) != 0) {
        close(in_p[0]);
        close(in_p[1]);
        free(words);
        free(av);
        return -1;
    }
    /* Our ends must not leak into the child (or into the next worker this
     * server starts): a leaked write end keeps the child's stdin open after
     * we close ours, and it would never see EOF. */
    (void)fcntl(in_p[1], F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_p[0], F_SETFD, FD_CLOEXEC);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, in_p[0], 0);
    posix_spawn_file_actions_adddup2(&fa, out_p[1], 1);
    posix_spawn_file_actions_addclose(&fa, in_p[0]);
    posix_spawn_file_actions_addclose(&fa, out_p[1]);
    pid_t pid = 0;
    extern char **environ;
    int   rc  = posix_spawn(&pid, av[0], &fa, NULL, av, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(in_p[0]);
    close(out_p[1]);
    free(words);
    free(av);
    if (rc != 0) {
        close(in_p[1]);
        close(out_p[0]);
        return -1;
    }

    (void)fcntl(out_p[0], F_SETFL, fcntl(out_p[0], F_GETFL) | O_NONBLOCK);
    *to_child   = in_p[1];
    *from_child = out_p[0];
    return (long long)pid;
#endif
}

/* Waits up to \p ms for input on stdin or on \p fd (-1: stdin alone). Bit 1:
 * stdin has bytes or is at EOF; bit 2: \p fd has bytes, EOF or an error (a
 * read then says which). 0 on timeout, -1 on error. */
static inline int kals_poll2(int fd, int ms) {
#ifdef _WIN32
    (void)fd;
    int r = kals_stdin_wait(ms);
    return r < 0 ? -1 : r;
#else
    struct pollfd p[2];
    p[0].fd      = 0;
    p[0].events  = POLLIN;
    p[0].revents = 0;
    p[1].fd      = fd;
    p[1].events  = POLLIN;
    p[1].revents = 0;
    int r        = poll(p, fd >= 0 ? 2 : 1, ms);
    if (r < 0) {
        return -1;
    }
    int bits = 0;
    if (p[0].revents != 0) {
        bits |= 1;
    }
    if (fd >= 0 && p[1].revents != 0) {
        bits |= 2;
    }
    return bits;
#endif
}

/* A non-blocking read of \p fd: bytes read, 0 at EOF, -2 when nothing is
 * there yet, -1 on error. */
static inline long long kals_fd_read(int fd, unsigned char *buf, unsigned long long cap) {
#ifdef _WIN32
    return (long long)_read(fd, buf, (unsigned int)cap);
#else
    ssize_t r = read(fd, buf, (size_t)cap);
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
        return -2;
    }
    return (long long)r;
#endif
}

/* Writes all \p n bytes to \p fd (blocking); bytes written, or -1 when the
 * reader is gone. */
static inline long long kals_fd_write(int fd, const unsigned char *buf, unsigned long long n) {
#ifdef _WIN32
    return (long long)_write(fd, buf, (unsigned int)n);
#else
    unsigned long long off = 0;
    while (off < n) {
        ssize_t w = write(fd, buf + off, (size_t)(n - off));
        if (w < 0 && errno == EINTR) {
            continue;
        }
        if (w <= 0) {
            return -1;
        }
        off += (unsigned long long)w;
    }
    return (long long)off;
#endif
}

/* 1 while child \p pid runs, 0 once it has exited (and is reaped). */
static inline int kals_child_alive(long long pid) {
#ifdef _WIN32
    (void)pid;
    return 0;
#else
    if (pid <= 0) {
        return 0;
    }
    int   st = 0;
    pid_t r  = waitpid((pid_t)pid, &st, WNOHANG);
    return r == 0 ? 1 : 0;
#endif
}

/* Kills process \p pid without reaping it: the caller's own wait collects it
   (an index worker, reaped by the loop). */
static inline void kals_kill(long long pid) {
    if (pid <= 0) {
        return;
    }
#ifdef _WIN32
    HANDLE h = OpenProcess(PROCESS_TERMINATE, FALSE, (DWORD)pid);
    if (h != NULL) {
        (void)TerminateProcess(h, 1);
        CloseHandle(h);
    }
#else
    (void)kill((pid_t)pid, SIGKILL);
#endif
}

/* Closes the child's pipes, kills it and reaps it. */
static inline void kals_child_stop(long long pid, int to_child, int from_child) {
#ifndef _WIN32
    if (to_child >= 0) {
        close(to_child);
    }
    if (from_child >= 0) {
        close(from_child);
    }
    if (pid > 0) {
        (void)kill((pid_t)pid, SIGKILL);
        int st = 0;
        (void)waitpid((pid_t)pid, &st, 0);
    }
#else
    (void)pid;
    (void)to_child;
    (void)from_child;
#endif
}

/* The child's resident size in MB, or -1 where the platform does not say
 * (only Linux's /proc is read; elsewhere the pass count alone recycles). */
static inline long long kals_child_rss_mb(long long pid) {
#if defined(__linux__)
    char path[64];
    snprintf(path, sizeof path, "/proc/%lld/statm", pid);
    FILE *f = fopen(path, "r");
    if (f == NULL) {
        return -1;
    }
    long long size = 0, res = 0;
    int       got  = fscanf(f, "%lld %lld", &size, &res);
    fclose(f);
    if (got != 2) {
        return -1;
    }
    return res * (long long)sysconf(_SC_PAGESIZE) / (1024 * 1024);
#else
    (void)pid;
    return -1;
#endif
}
