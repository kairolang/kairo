/* --- The Kairo Project --------------------------------- Lib/std/env.h --- *
 *
 *   The host side of std/env.k. Stage 1 has no eval if yet, so a per-OS
 *   query cannot be chosen in Kairo; the C preprocessor chooses here, the
 *   way write.h chooses write(2)'s header.
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
 *   Copyright (c) 2026 Dhruvan Kartik
 *
 * ------------------------------------------------------------------------ */

#pragma once

#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#elif defined(__APPLE__)
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#elif defined(__linux__)
#include <unistd.h>
#elif defined(__FreeBSD__) || defined(__NetBSD__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

/* This executable's absolute path: UTF-8, '/'-separated on every host, in a
 * malloc'd block of *len bytes (not NUL-terminated; the length is the
 * contract). NULL with *len 0 when the OS will not say -- OpenBSD has no
 * query, wasm has no executable path -- and never a block with *len 0, so
 * the caller tests the length alone (Kairo has no null pointer to compare
 * against) and frees with free() when it is nonzero. */
static inline unsigned char *kstd_exe_path(size_t *len) {
    *len = 0;
#if defined(_WIN32)
    /* 32768 wide chars is the longest path Windows has (\\?\ form). */
    wchar_t *w = (wchar_t *)malloc(32768 * sizeof(wchar_t));
    if (w == NULL) { return NULL; }
    DWORD wn = GetModuleFileNameW(NULL, w, 32768);
    if (wn == 0 || wn == 32768) { free(w); return NULL; }
    int n = WideCharToMultiByte(CP_UTF8, 0, w, (int)wn, NULL, 0, NULL, NULL);
    if (n <= 0) { free(w); return NULL; }
    unsigned char *out = (unsigned char *)malloc((size_t)n);
    if (out == NULL) { free(w); return NULL; }
    WideCharToMultiByte(CP_UTF8, 0, w, (int)wn, (char *)out, n, NULL, NULL);
    free(w);
    for (int i = 0; i < n; ++i) {
        if (out[i] == '\\') { out[i] = '/'; }
    }
    *len = (size_t)n;
    return out;
#elif defined(__APPLE__)
    char     buf[4096];
    uint32_t size = sizeof(buf);
    char     real[PATH_MAX];
    if (_NSGetExecutablePath(buf, &size) != 0) { return NULL; }
    if (realpath(buf, real) == NULL) { return NULL; }
    size_t n = strlen(real);
    if (n == 0) { return NULL; }
    unsigned char *out = (unsigned char *)malloc(n);
    if (out == NULL) { return NULL; }
    memcpy(out, real, n);
    *len = n;
    return out;
#elif defined(__linux__)
    char    buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf));
    /* n == sizeof(buf) means it may have been cut short: refuse it. */
    if (n <= 0 || (size_t)n >= sizeof(buf)) { return NULL; }
    unsigned char *out = (unsigned char *)malloc((size_t)n);
    if (out == NULL) { return NULL; }
    memcpy(out, buf, (size_t)n);
    *len = (size_t)n;
    return out;
#elif defined(__FreeBSD__) || defined(__NetBSD__)
    char   buf[4096];
    size_t size = sizeof(buf);
#if defined(__FreeBSD__)
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
#else
    int mib[4] = {CTL_KERN, KERN_PROC_ARGS, -1, KERN_PROC_PATHNAME};
#endif
    if (sysctl(mib, 4, buf, &size, NULL, 0) == -1 || size == 0) { return NULL; }
    size_t n = strnlen(buf, size);
    if (n == 0) { return NULL; }
    unsigned char *out = (unsigned char *)malloc(n);
    if (out == NULL) { return NULL; }
    memcpy(out, buf, n);
    *len = n;
    return out;
#else
    return NULL;
#endif
}
