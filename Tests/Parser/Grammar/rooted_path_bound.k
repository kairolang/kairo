// A bound may be a rooted path: `fn <T impl ::m::I>` was S049E
// "expected '>' to close generic parameter list", and `requires T impl ::m::I`
// S052E. A leading `::` starts the path at the file's root, as `::m::f()`
// already does in an expression: inside `module m`, `impl I` is m's own `I`
// and `impl ::I` the file's. Bounds only: a generic parameter's `impl` /
// `derives`, an inherit list (`class D derives ::m::Base`) and a requires
// constraint. The docs give no rooted type anywhere else, so `var v: ::m::P`
// stays S053E. An unknown rooted head is R021E as usual.

interface I {
    fn get(self) -> i32
}

module m {
    pub interface I {
        fn other(self) -> i32
    }

    pub fn <T impl ::I> use_root(x: T) -> i32 { return x.get() }
    pub fn <T impl I> use_near(x: T) -> i32 { return x.other() }
    pub class Base { pub var v: i32 = 0 }
}

struct S { var v: i32 }
extend S impl I { fn get(self) -> i32 { return self.v } }
extend S impl m::I { fn other(self) -> i32 { return self.v + 1 } }

class D derives ::m::Base { }

fn <T> f2(x: T) -> i32 requires T impl ::m::I { return x.other() }

fn main() -> i32 {
    var s = S{v: 1}
    var d = D()
    return m::use_root(s) + m::use_near(s) + f2(s) + d.v - 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
// RUN: %t.exe
// RUN: { %kairo %S/Inputs/rooted_path_bound_unknown.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=UNKNOWN --implicit-check-not="error ["
// UNKNOWN: rooted_path_bound_unknown.k:1:14: error [R021E]: unknown type name 'Nope'
// UNKNOWN: rooted_path_bound_unknown.k:2:19: error [R021E]: unknown type name 'Nobase'
// RUN: { %kairo %S/Inputs/rooted_path_not_a_bound.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOTBOUND --implicit-check-not="error ["
// NOTBOUND: rooted_path_not_a_bound.k:2:27: error [S053E]: expected type, found '::'
