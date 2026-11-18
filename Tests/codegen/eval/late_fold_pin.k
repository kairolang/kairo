// EVAL.md 4.2b, the agreement pin. An `eval` constant read through a type
// fact is still a C++ constexpr clang computes; when the late fold decided
// an `eval if` on it, codegen asserts that clang's value is the one the fold
// read. --test-fold-lie makes the fold read every triviality fact inverted,
// as a LifecycleFacts bug would: the fold then keeps the other branch, and
// the pin turns the disagreement into a failed build.
struct Plain { var x: i32 }

eval PLAIN_TC = is_trivially_copyable!(Plain)

eval if PLAIN_TC {
    fn which() -> i32 { return 0 }
} else {
    fn which() -> i32 { return 1 }
}

fn main() -> i32 { return which() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: static_assert({{ *}}PLAIN_TC{{ *}}=={{ *}}true{{ *}},

// REQUIRES: clang
// RUN: rm -rf %t.d %t.lie.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
// RUN: not %kairo %s --test-fold-lie -o %t.lie.exe --cache-dir %t.lie.d > %t.lie.out 2>&1
// RUN: %FileCheck %s --check-prefix=LIE < %t.lie.out
// LIE: Kairo's type facts and clang disagree on its value
