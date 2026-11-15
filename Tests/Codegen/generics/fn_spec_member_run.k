// A full specialization of a member template, a static one and an extension
// member: declared in the class (or the extension's scope) after its
// primary, wherever it was written, and defined out of line.

class C {
    var v: i32 = 7
    fn <> m<i32>(self) -> i32 { return self.v + 1 }
    fn <T> m(self) -> i32 { return 1 }
    static fn <T> s() -> i32 { return 1 }
    static fn <> s<bool>() -> i32 { return 5 }
}

extend C {
    fn <T> e(const self) -> i32 { return 1 }
    fn <> e<u8>(const self) -> i32 { return self.v * 2 }
}

fn main() -> i32 {
    var c = C()
    if c.m<i32>() != 8 || c.m<u8>() != 1 { return 1 }
    if C::s<bool>() != 5 || C::s<i32>() != 1 { return 2 }
    if c.e<u8>() != 14 || c.e<i64>() != 1 { return 3 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
