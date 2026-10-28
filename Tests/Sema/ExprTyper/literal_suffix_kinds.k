// Which type each literal suffix names (primitives.mdx, Integers and
// Floating-Point). The lexer only knows `iN` / `uN` / `fN` widths; every
// other suffix used to fall through to a default without a word: `1usize`
// and `1f32` were i8 (the value's minimum width) and `1.5bf16` an f64.
// They are read from the suffix's text now: usize / isize are the target's
// pointer width, a float suffix on an integer body is that float, `bf16` is
// bf16, and a suffix that names no type is SC074E.

fn main() -> i32 {
    var a = 1usize
    var b = -1isize
    var c = 18446744073709551615usize
    var d = 1f32
    var e = 2f64
    var f = 1.5bf16
    var g = 1.5f16
    var h = 3u128
    var bad1 = 1.5f8
    var bad2 = 1u7
    var bad3 = 1.5xyz
    var bad4 = 1.5i32
    var bad5 = 7q
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: a : usize
// SEMA: b : isize
// SEMA: c : usize
// SEMA: d : f32
// SEMA: e : f64
// SEMA: f : bf16
// SEMA: g : f16
// SEMA: h : u128

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:18:16: error [SC074E]: unknown float literal suffix 'f8'
// DIAG: {{.*}}:19:16: error [SC074E]: unknown integer literal suffix 'u7'
// DIAG: {{.*}}:20:16: error [SC074E]: unknown float literal suffix 'xyz'
// DIAG: {{.*}}:21:16: error [SC074E]: unknown float literal suffix 'i32'
// DIAG: {{.*}}:22:16: error [SC074E]: unknown integer literal suffix 'q'
// END-GENERATED-CHECKS(DIAG)
