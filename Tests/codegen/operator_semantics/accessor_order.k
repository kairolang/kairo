// OperatorSemantics: a lang item's pure accessor (PureAccessors: string's
// length / as_ptr / codepoints / capacity, a nullable's `__value()` and
// `is_null()`) is no effect, so two of them in one expression bind
// nothing. It still READS its object: when another operand can change that
// object, the accessor is read first, as written.

import std::io::*

fn grow(s: *string) -> usize { *s = "abcd"; return 0 }

fn main() -> i32 {
    var a = "xy"
    var b = "xyz"
    var same = a.length() + b.length()
    var s = "ab"
    var before = s.length() + grow(&s)
    println(f"{same} {before} {s.length()}")          // OUT: 5 2 4
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}accessor_order.k
// CXX: same = static_cast<{{.*}}>(static_cast<{{.*}}>(a.length()) + static_cast<{{.*}}>(b.length()));
// CXX: = s.length();
// CXX-NEXT: grow(
