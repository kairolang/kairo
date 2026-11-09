// A dependent operator probe or pointer-step wrapper is a C++ lambda;
// as a subscript index, `v[[](...)...]` opens a C++ attribute and clang rejects
// it ("consecutive left square brackets"). The probes are parenthesized.

class Host derives Mixin<Host> {
    fn n(self) -> usize { return 3; }
    var xs: [i32; 4] = [10, 20, 30, 40];
}
class <T: type> Mixin {
    inline fn dyn(self) -> *T { return unsafe (&self as *T); }
    pub fn go(self) -> i32 {
        return self.dyn()->xs[self.dyn()->n() - 1];
    }
}
fn main() -> i32 { var h = Host(); return h.go() }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// RUN: %t.exe; test $? -eq 30
