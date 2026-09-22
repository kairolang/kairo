// Arguments are evaluated left to right whatever clang does; the tree says
// so. `g` counts calls, so the order shows in the digits.

fn g(@inout n: i32) -> i32 { n += 1; return n * 10 }
fn f(a: i32, b: i32) -> i32 { return a * 100 + b }
fn one(a: i32) -> i32 { return a }

fn main() -> i32 {
    var n = 0;
    var c = false;
    var skipped = if c { f(g(&n), g(&n)) } else { 0 }; // inside the branch: never runs, n stays 0
    var seq = f(g(&n), g(&n));                         // 10 * 100 + 20
    var untouched = one(g(&n));                        // one impure arg: no rewrite, 30
    return seq - 1000 + untouched + skipped            // 20 + 30 == 50
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// Two calls are rewritten, in source order: the one in the branch (which is
// never evaluated -- the block sits where the call sat) and `seq`'s. `one`
// has a single impure argument, so there is no order to write down and no
// local is minted.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: __kairo_arg0
// IR: __kairo_arg1
// IR: __kairo_arg2
// IR: __kairo_arg3
// IR-NOT: __kairo_arg4

// REQUIRES: clang
// `-o` names a DIRECTORY: the entry TU's object plus one per builtin TU.
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 50
