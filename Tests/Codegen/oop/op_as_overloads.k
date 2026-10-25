// `op as` overloaded on its target type (casting.md, User-Defined
// Conversions): the `as` target picks the overload.
//
// XFAIL: *
// Waiting on RedeclMerge telling `op as` overloads apart by return type:
// the second one is R041E "class member 'op' cannot be redeclared". (Note
// the name, too: 'op', not 'op as'.) A single `op as` works.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class Temp {
    var c: i32
    fn Temp(self, c: i32) { self.c = c }
    fn op as(self) -> i32 { return self.c }
    fn op as(self) -> i64 { return (self.c * 2) as i64 }
}

fn main() -> i32 {
    var t = Temp(10)
    var a = t as i32
    var b = t as i64
    return a + (b as i32)                        // 10 + 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 30
