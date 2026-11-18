// Operators and literals from a macro body, in the SAME file. Every body
// token, and every argument token substituted into a body, reaches the
// parser wrapped (kind TkMacroExpand, imm the expansion record), and three
// readers took the wrapper at face value:
//
//   - an operator node kept the wrapped token, and Sema's operator typing
//     switched on its kind: `a + b` in any body was SC066E "operator '+' is
//     not defined on primitives";
//   - a literal node read the record index as a payload index: SC073E "no
//     immediate data" when it ran off this file's literal list (`wrap!(3)`),
//     and some OTHER literal of the file when it did not;
//   - EmitIR spelled the literal from the token's range, which is the
//     invocation: `seven!()` was emitted as a numeric constant.
//
// `five` holds this file's first integer literal, so the second failure
// would read `5` for `seven!()`.

fn five() -> i32 { return 5 }
fn h(x: i32) -> i32 { return x }

macro seven!() { 7 }
macro half!() { 0.5 }
macro add!(a, b) { a + b }
macro twice!(x) { h(x) + h(x) }
macro wrap!(x) { h(h(x)) }
macro neg!(x) { -x }
macro bump!(v) { v += 1 }

fn main() -> i32 {
    var n = 2
    bump!(n)                       // 3
    var t = add!(n, seven!())      // 10
    t = t + twice!(n)              // 16
    t = t + wrap!(3)               // 19
    t = t + neg!(1)                // 18
    if half!() < 1.0 { t = t + 1 } // 19
    return t
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 19
