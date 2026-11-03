// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 3
//
// `self` passed to a macro inside a method binds to the receiver, as it does
// written out. The substituted token reached Sema wrapped as a macro
// expansion, and the `self` checks read only its raw kind, so it stayed
// unbound: I003E "'self' survived name resolution unbound".

macro bump_if!(cond, place) { if (cond) { place += 1 } }

class C {
    pub var n: i32 = 0
    fn has(self) -> bool { return self.n > 0 }
    fn mark(self) {
        self.n = 1
        bump_if!(self.has(), self.n)
        bump_if!(self.n == 2, self.n)
    }
}

fn main() -> i32 {
    var c: C
    c.mark()
    return c.n
}

// DIAG-NOT: error
