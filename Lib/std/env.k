/// --- The Kairo Project -------------------------------- Lib/std/env.k --- ///
///
///   The process's view of its host: `exe_path`.
///
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "env.h"   // the per-OS query; stdlib.h for free

import string::*

/// Returns this executable's absolute path as UTF-8.
///
/// The path is '/'-separated on every host (Windows backslashes are converted) and has symlinks
/// resolved where the OS resolves them (`/proc/self/exe` on Linux, `realpath` on macOS). It is a
/// `string`, not a path type: the bytes are exactly what the OS reported.
///
/// \returns the absolute path, or `""` when the OS cannot say
/// \example
/// ```kairo
/// import std::io
/// import std::env
///
/// fn main() -> i32 {
///     io::println(env::exe_path())
///     return 0
/// }
/// ```
pub fn exe_path() -> string {
    var n: usize = 0
    unsafe {
        var unsafe *p = kstd_exe_path(unsafe &n)
        if n == 0 { return "" }               // env.h: no block when there is no path
        var s = string(p as *const u8, n)
        free(p)
        return s
    }
}
