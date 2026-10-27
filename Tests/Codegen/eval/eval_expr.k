// `eval e` as an expression (EVAL.md §0): C++ computes `e` in place, at
// compile time, so it is an eval context (a run-time variable in it is
// SC001E). `eval { ... }` in a function body has no meaning yet: SC116E.
eval fn sq(x: i32) -> i32 { return x * x }

fn main() -> i32 {
    var a = eval sq(3)
    return a                                    // 9
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: signed int a ={{ ?}}[&]() consteval {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9

// RUN: sed -e 's/var a = eval sq(3)/var n = 3  var a = eval sq(n)  eval { var t = 1 }/' %s > %t.bad.k
// RUN: { %kairo %t.bad.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD-DAG: error [SC001E]: an eval context reads only compile-time values; 'n' is a run-time local
// BAD-DAG: error [SC116E]: an 'eval' block in a function body is not yet supported
