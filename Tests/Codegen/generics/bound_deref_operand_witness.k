// An operator applied to a dereferenced pointer of a bounded type parameter
// goes through the bound's witness, not a native C++ operator. `Rec` has no
// `==` of its own: only the `extend ... impl Eqx` provides one, so a native
// `==` on the operands would not compile, and the call counter shows the
// witness ran once per comparison.

interface Eqx {
    fn op == (const self, const o: Self) -> bool
}

var g_calls: i32 = 0

class Rec {
    pub var v: i32 = 0
    fn Rec(self, v: i32) { self.v = v }
}

extend Rec impl Eqx {
    pub fn op == (const self, const o: Self) -> bool {
        g_calls += 1
        return self.v == o.v
    }
}

fn <T impl Eqx> same(const x: T, p: *T) -> bool { return *p == x }

fn main() -> i32 {
    var a = Rec(3)
    var b = Rec(3)
    var c = Rec(4)
    if !same(a, &b) { return 1 }
    if same(a, &c) { return 2 }
    if g_calls != 2 { return 3 }
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
