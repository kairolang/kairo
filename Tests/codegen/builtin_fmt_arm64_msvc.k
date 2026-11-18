// The builtin library builds on a target without f80. Windows on ARM has
// no x87 (and MSVC's `long double` is binary64), so a builtin signature
// that names f80 unconditionally -- FmtBuf::put_f80 once was one -- fails
// with P003E inside Lib/builtin/fmt/fmt_buf.k for EVERY program on that
// target, whether or not the user wrote f80. An f-string pulls FmtBuf in;
// f128 stays available there. Objects only: nothing here links or runs.

fn main() -> i32 {
    var d: f64 = 1.5
    var q: f128 = 2.5
    var s = f"{d} {q}"
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-aarch64-windows-msvc
// RUN: rm -rf %t.d
// RUN: { %kairo %s -c --target=aarch64-pc-windows-msvc --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: test -f %t.d/builtin_fmt_arm64_msvc.o
// DIAG-NOT: error
// DIAG-NOT: fmt_buf.k
