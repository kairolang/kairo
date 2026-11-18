// std::env::exe_path (Lib/std/env.k): this executable's absolute path,
// '/'-separated, with no trailing newline or NUL. The binary is built to a
// known %t path, so the printed path must be exactly that file (EXACT):
// absolute, symlinks resolved by the OS (lit's %t is not under one here),
// and the same bytes `realpath` gives the shell.

import std::io
import std::env

fn main() -> i32 {
    var p = env::exe_path()
    io::println(p)
    if p.length() == 0 { return 1 }
    if p.as_ptr()[0] != 47 { return 2 }         // absolute: starts with '/'
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// UNSUPPORTED: system-windows
// RUN: rm -rf %t.d %t.dir && mkdir -p %t.dir
// RUN: %kairo %s -o %t.dir/exe_path_probe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.dir/exe_path_probe > %t.out
// RUN: realpath %t.dir/exe_path_probe > %t.want
// RUN: diff %t.want %t.out
