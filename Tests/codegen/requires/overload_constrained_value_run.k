// Constraint ordering by a value predicate the C++ template head carries:
// `requires sizeof T <= 8` beats no clause, in Kairo and in clang alike, so
// the program exits 0 only when both picked it.

fn <T> c(const x: T) -> i32 requires sizeof T <= 8 {
    return 100
}

fn <T> c(const x: T) -> i32 {
    return 200
}

fn main() -> i32 {
    var n = 3
    return c(n) - 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: template<class T> requires(((sizeof(T)) <=(8))) signed int c(T const & x) noexcept;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
