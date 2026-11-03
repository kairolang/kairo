/// --- The Kairo Project -------------------------------- Lib/std/env.k --- ///
///
///   The process's view of its host: `exe_path`.
///
///   SPDX-License-Identifier: Apache-2.0 WITH KAIRO-RUNTIME-EXCEPTION
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

ffi "c" import "env.h"   // the per-OS query; stdlib.h for free

import string::*

/// This executable's absolute path as UTF-8, '/'-separated on every host
/// (Windows' backslashes included), symlinks resolved where the OS resolves
/// them (Linux's /proc/self/exe, macOS's realpath). "" when the OS will not
/// say. A string, not a path type: the bytes are exactly what the OS gave.
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
