// An unoptimized build (-O0, the debug profile) checks `@assume(c)`: a false
// `c` traps at that statement. An optimized build hands `c` to the optimizer
// as clang's `__builtin_assume` and tests nothing.

fn div_by(n: i32, d: i32) -> i32 {
    @assume(d > 0)
    return n / d
}

fn main(argc: i32) -> i32 {
    // argc is 1 with no arguments and 2 with one: the divisor is 1 or 0.
    return div_by(10, 2 - argc) - 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=DBG
// DBG-LABEL: CODEGEN C++: {{.*}}assume_checked_unoptimized.k
// DBG-NOT: {{^ *}}__builtin_assume(
// DBG: ? static_cast<void>(0){{ *}}: __builtin_trap());
// DBG: return

// RUN: { %kairo %s --print-ir -O0 2>&1 || true; } | %FileCheck %s --check-prefix=DBG

// RUN: { %kairo %s --print-ir -O1 2>&1 || true; } | %FileCheck %s --check-prefix=OPT
// RUN: { %kairo %s --print-ir --profile release 2>&1 || true; } | %FileCheck %s --check-prefix=OPT
// OPT-LABEL: CODEGEN C++: {{.*}}assume_checked_unoptimized.k
// OPT-NOT: static_cast<void>(0)
// OPT: {{^ *}}__builtin_assume(
// OPT: return

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
// RUN: not --crash %t.exe one
