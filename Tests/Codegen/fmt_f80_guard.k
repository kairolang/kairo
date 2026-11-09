// An f80 hole formats through FmtBuf::put_f80, which Lib/builtin/fmt/fmt_buf.k
// declares under `eval if` only where C++ `long double` is x87 extended (x86,
// but not MSVC or Android). On x86_64 Linux the hole runs, sign and all; on a
// target without x87 the error is TypeResolve's P003E at the spelling, and the
// builtin library itself raises nothing (its put_f80 is not declared there),
// so no FmtBuf or put_f80 diagnostic leaks out of it.

import std::io

fn main() -> i32 {
    var x: f80 = -1.25
    var y: f80 = 0.0
    io::println(f"{x} {y} {x:.3}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-linux, host-x86_64
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: -1.25 0 -1.25
//
// RUN: { %kairo %s --target=aarch64-unknown-linux-gnu --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// ARM64:     fmt_f80_guard.k:11:{{[0-9]+}}: error [P003E]: 'f80' requires x87, which aarch64 does not have
// ARM64-NOT: fmt_buf
// ARM64-NOT: put_f80
//
// RUN: { %kairo %s --target=x86_64-pc-windows-msvc --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// MSVC:     fmt_f80_guard.k:11:{{[0-9]+}}: error [P003E]: 'f80' is unavailable on 'x86_64-pc-windows-msvc': x87 exists but this ABI's 'long double' is binary64
// MSVC-NOT: fmt_buf
// MSVC-NOT: put_f80
