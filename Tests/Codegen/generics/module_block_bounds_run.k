// Run form. A generic declared in a `module` block keeps its `impl` bounds. Nothing
// in a module block had its requires clause recorded in the bound table
// (ConstraintExtraction walked only the file's own top level), so a call of
// a requirement through `T` was R051E "'T' is declared with no bound" on a
// function, a `requires` clause and a class alike, and a non-conforming
// argument was not caught.

interface Big { fn big(const self) -> i32 }

class W impl Big {
    pub var n: i32
    fn W(self) { self.n = 0 }                   // Holder's T field needs one: P327
    fn W(self, n: i32) { self.n = n }
    fn big(const self) -> i32 = self.n
}

module m {
    pub interface Small { fn small(const self) -> i32 }

    pub fn <T impl Big> deep(x: T) -> i32 { return x.big() + 1 }
    pub fn <T> req(x: T) -> i32 requires T impl Big { return x.big() + 2 }

    pub class <T impl Big> Holder {
        pub var t: T
        fn Holder(self, t: T) { self.t = t }
        pub fn get(self) -> i32 { return self.t.big() + 3 }
    }

    pub fn <T impl Small> tiny(x: T) -> i32 { return x.small() }

    module inner { pub fn <T impl Big> nested(x: T) -> i32 { return x.big() + 4 } }
}

fn main() -> i32 {
    var h = m::Holder<W>(W(1))
    var ok = m::deep(W(1)) + m::req(W(1)) + h.get() + m::inner::nested(W(1))   // 2 + 3 + 4 + 5
    return ok
}

// --- lit wiring -----------------------------------------------------------
// The conforming half of Sema/Check/module_block_bounds.k, compiled and run.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 14
