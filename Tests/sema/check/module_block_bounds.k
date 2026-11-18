// A generic declared in a `module` block keeps its `impl` bounds. Nothing
// in a module block has its requires clause recorded in the bound table
// (ConstraintExtraction walks the module block, not only the file's own top
// level), so a call of a requirement through `T` is not R051E "'T' is
// declared with no bound" on a function, a `requires` clause or a class, and
// a non-conforming argument is caught.

interface Big { fn big(const self) -> i32 }

class W impl Big {
    pub var n: i32
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

    pub {
        fn <T impl Big> grouped(x: T) -> i32 { return x.big() }
        type <T impl Big> Al = T
    }
}

// A visibility group at file scope, and an alias bound (meaningless: one
// error, once, whichever list reaches the alias).
pub {
    fn <T impl Big> top_grouped(x: T) -> i32 { return x.big() }
    type <T impl Big> Bl = T
}

fn main() -> i32 {
    var h = m::Holder<W>(W(1))
    var ok = m::deep(W(1)) + m::req(W(1)) + h.get() + m::inner::nested(W(1))   // 2 + 3 + 4 + 5
    return ok + m::deep(7) + m::grouped(W(1)) + m::grouped(8) + top_grouped(9)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      module_block_bounds.k:34:15: warning [SC016W]: a conformance constraint is meaningless on a type alias
// CHECK-NEXT: module_block_bounds.k:42:11: warning [SC016W]: a conformance constraint is meaningless on a type alias
// CHECK-NEXT: module_block_bounds.k:48:17: error [SC162E]: 'i32' does not conform to 'Big'
// CHECK-NEXT: module_block_bounds.k:19:13: note [I900N]: required by this bound
// CHECK:      module_block_bounds.k:48:49: error [SC162E]: 'i32' does not conform to 'Big'
// CHECK-NEXT: module_block_bounds.k:33:13: note [I900N]: required by this bound
// CHECK:      module_block_bounds.k:48:65: error [SC162E]: 'i32' does not conform to 'Big'
// CHECK-NEXT: module_block_bounds.k:41:9: note [I900N]: required by this bound
// CHECK-NOT:  {{error|warning}}
