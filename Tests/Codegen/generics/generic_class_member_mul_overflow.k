// The overflow intrinsics are callable from a member of a generic class: the
// call is resolved against the instantiated type, so `__builtin_mul_overflow<T>`
// with T = u64 type-checks (no R057E) and reports overflow the way the
// instance's arithmetic does.

class <T> C {
    fn m(self, a: T, b: T) -> bool {
        var r: T = 0
        return __builtin_mul_overflow<T>(a, b, &r)
    }
}
fn main() -> i32 {
    var c = C<u64>()
    var big: u64 = 0xFFFFFFFFFFFFFFFF
    if !c.m(big, 2) { return 1 }
    if c.m(3, 4) { return 2 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe; test $? -eq 0
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe; test $? -eq 0
