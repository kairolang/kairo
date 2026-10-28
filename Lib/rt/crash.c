/* --- The Kairo Project ----------------------------- Lib/rt/crash.c --- */
/*
 *   See rt/crash.h for the contract. Everything here is on the list of
 *   async-signal-safe functions (write, sigaction, sigprocmask, abort) or
 *   is a compiler builtin; keep it that way.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 */
/* The runtime builds as strict ISO C, which hides sigaction and
 * sigprocmask; ask for POSIX before any header. */
#if !defined(_WIN32) && !defined(__wasm__) && !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif

#include "rt/crash.h"

#include <stdlib.h>

#if defined(_WIN32)
#include <io.h>
#include <signal.h>
#define KAIRO_RT_CRASH_WIN_ 1
#elif defined(__wasi__) || defined(__wasm__)
#include <errno.h>
#include <unistd.h>
#define KAIRO_RT_CRASH_WASM_ 1
#else
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#define KAIRO_RT_CRASH_POSIX_ 1
#endif

/* Set by the first crash. A second one (another thread crashing at the
 * same time, or a fault while this one writes) must not write over the
 * buffer below or wait on anything: it goes straight to termination. */
static int kairo_rt_crashing_;

/* The message and its newline, so one write(2) carries both: at most
 * PIPE_BUF bytes, which a pipe takes atomically, so another thread's
 * output cannot land in the middle of it. Static, not on the stack: the
 * stack may be what broke. Only the guard's winner touches it. */
static unsigned char kairo_rt_crash_buf_[KAIRO_RT_CRASH_MAX + 1];

static void kairo_rt_crash_put_(const unsigned char *p, size_t len) {
    size_t off = 0;
    /* Bounded: a write that makes no progress twice in a row ends it. */
    int stalls = 0;
    while ((off < len) && (stalls < 2)) {
#if defined(KAIRO_RT_CRASH_WIN_)
        int w = _write(2, p + off, (unsigned)(len - off));
        if (w <= 0) { return; }   /* nothing left to report it on */
#else
        ssize_t w = write(2, p + off, len - off);
        if (w < 0) {
            if (errno == EINTR) { ++stalls; continue; }
            return;
        }
        if (w == 0) { ++stalls; continue; }
#endif
        stalls = 0;
        off += (size_t)w;
    }
}

/* SIGABRT to its default action, unblocked, then abort(): a handler the
 * program installed would run Kairo code on the state that just failed.
 * If abort() somehow returns, trap. */
__attribute__((noreturn)) static void kairo_rt_crash_die_(void) {
#if defined(KAIRO_RT_CRASH_POSIX_)
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sa.sa_flags   = 0;
    sigemptyset(&sa.sa_mask);
    (void)sigaction(SIGABRT, &sa, (struct sigaction *)0);
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGABRT);
    (void)sigprocmask(SIG_UNBLOCK, &set, (sigset_t *)0);
#elif defined(KAIRO_RT_CRASH_WIN_)
    (void)signal(SIGABRT, SIG_DFL);
#endif
    abort();
    __builtin_trap();
}

/* The re-entry guard and the one write, shared by every entry below. */
static void kairo_rt_crash_say_(const unsigned char *msg, size_t len) {
    if (__atomic_exchange_n(&kairo_rt_crashing_, 1, __ATOMIC_SEQ_CST) != 0) {
        kairo_rt_crash_die_();
    }
    if (msg == (const unsigned char *)0) { len = 0; }
    if (len > 0) {
        if (len > KAIRO_RT_CRASH_MAX) { len = KAIRO_RT_CRASH_MAX; }
        size_t i = 0;
        for (; i < len; ++i) { kairo_rt_crash_buf_[i] = msg[i]; }
        kairo_rt_crash_buf_[len] = '\n';
        kairo_rt_crash_put_(kairo_rt_crash_buf_, len + 1);
    }
}

void kairo_rt_crash(const unsigned char *msg, size_t len) {
    kairo_rt_crash_say_(msg, len);
    kairo_rt_crash_die_();
}

/* `__builtin_crash`: the message, then _Exit with the caller's code: no
 * atexit handlers, no stdio flush, as for a crash. */
void kairo_rt_crash_exit(const unsigned char *msg, size_t len, int code) {
    kairo_rt_crash_say_(msg, len);
    _Exit(code);
}

/* `__builtin_signal`: the message, then \p sig at its default action,
 * unblocked, so the process ends as that signal would end it (a core for
 * SIGSEGV, the shell's 128+n). A signal the target lacks, or one that
 * returns (ignored by a parent's mask on some systems), falls to abort(). */
void kairo_rt_signal(const unsigned char *msg, size_t len, int sig) {
    kairo_rt_crash_say_(msg, len);
#if defined(KAIRO_RT_CRASH_POSIX_)
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sa.sa_flags   = 0;
    sigemptyset(&sa.sa_mask);
    (void)sigaction(sig, &sa, (struct sigaction *)0);
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, sig);
    (void)sigprocmask(SIG_UNBLOCK, &set, (sigset_t *)0);
    (void)raise(sig);
#elif defined(KAIRO_RT_CRASH_WIN_)
    (void)signal(sig, SIG_DFL);
    (void)raise(sig);
#else
    (void)sig;
#endif
    kairo_rt_crash_die_();
}
