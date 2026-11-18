// An override whose by-value `string` parameter is written exactly as the
// base declares it overrides: the virtual call through a base pointer reaches
// the override.

class Base {
    virtual fn f(self, s: string) -> i32 { return 1 }
}
class D derives Base {
    override fn f(self, s: string) -> i32 { return 7 }
}
fn main() -> i32 {
    var d = D()
    var b: *Base = &d
    return b->f("x") - 7
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
