/* --- The Kairo Project ----------------------- Compiler/Native/Win32.hh --- */
/*
 *   The compiler's Win32 calls, as plain-typed functions.
 *
 *   No header a Kairo module imports may include <windows.h>: ffi puts every
 *   name a header brings into the importing module's lookup, and Win32's (a
 *   winnt.h enumerator `TokenSource` against the Preprocessor's class, the
 *   GENERIC_READ family of macros ffi cannot name) broke the Windows build of
 *   the compiler. <windows.h> lives in Win32.cpp alone, which build.py compiles
 *   into every binary; off Windows it compiles to nothing, and nothing calls
 *   these there (every call sits under `_WIN32` / `defined!(_WIN32)`).
 *
 *   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
 */
#pragma once

#include <cstddef>

namespace kairo::win32 {

/// Maps the file at UTF-8 path \p path (\p len bytes, not NUL-terminated)
/// read-only. On success *data / *size are the view and its length; an empty
/// file succeeds with *size 0 and *data a static, non-null empty buffer that is
/// NOT a mapping (never unmap it). false when the file cannot be opened, sized
/// or mapped.
bool map_readonly(const char *path, size_t len, unsigned char **data, size_t *size);

/// Unmaps a view map_readonly returned.
void unmap(void *data);

/// This executable's path as UTF-8, '/'-separated, into \p buf (\p cap bytes).
/// Returns its length, or 0 when the OS will not say or it does not fit.
size_t exe_path_utf8(char *buf, size_t cap);

/// Moves \p from to \p to (UTF-8, \p flen / \p tlen bytes each), directories
/// included, which llvm::sys::fs::rename does not do on Windows. Fails if \p to
/// exists. MoveFileExW, write-through.
bool move_path(const char *from, size_t flen, const char *to, size_t tlen);

/// Console input and output code pages to UTF-8 (KLocale's init).
void console_utf8();

/// Starts a detached thread running fn(arg) with a \p stack_bytes stack
/// reservation (KThread's pool workers).
void spawn_thread(void (*fn)(void *), void *arg, size_t stack_bytes);

/// Turns on ANSI escape processing for stderr's console and reports its width
/// in *cols. false when stderr is not a console that takes it (the progress
/// line then stays off).
bool enable_vt_stderr(int *cols);

}  // namespace kairo::win32
