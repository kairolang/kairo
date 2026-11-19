// OperatorSemantics: a lang item's pure accessor (PureAccessors: string's
// size / data / codepoints / capacity, a nullable's `__value()` and
// `is_null()`) is no effect, so two of them in one expression bind
// nothing. It still READS its object: when another operand can change that
// object, the accessor is read first, as written.

import std::io::*

fn grow(s: *string) -> usize { *s = "abcd"; return 0 }

fn main() -> i32 {
    var a = "xy"
    var b = "xyz"
    var same = a.size() + b.size()
    var s = "ab"
    var before = s.size() + grow(&s)
    println(f"{same} {before} {s.size()}")          // OUT: 5 2 4
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}accessor_order.k
// CXX: same = static_cast<{{.*}}>(static_cast<{{.*}}>(a.size()) + static_cast<{{.*}}>(b.size()));
// CXX: = s.size();
// CXX-NEXT: grow(
