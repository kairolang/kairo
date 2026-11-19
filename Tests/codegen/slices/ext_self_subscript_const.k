// A generic extension of `[T;]` subscripts `self`; with T a const element
// the instance is `Slice<const T>`, which declares no `op []=`, and the call
// still reaches its `op []`.

extend <T> [T;] {
    fn head(const self) -> *const T { return &self[0] }
}

fn main() -> i32 {
    var a: [i32; 3] = [7, 8, 9]
    var m: [i32;] = a[0..3]; m[0] = 7
    var c: [const i32;] = a[1..3]
    if *m.head() != 7 { return 1 }
    if *c.head() != 8 { return 2 }
    return 100
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 100
