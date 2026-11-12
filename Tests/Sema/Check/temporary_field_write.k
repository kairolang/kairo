// A field of a temporary is not a place. `g().v = 2`, `b[0].v = 3`
// through a by-value `op []`, and `m[0].v = 3` through a by-value C++
// `operator[]` passed Sema and failed in clang (CL001E "expression is not
// assignable"). A member of a temporary is an xvalue, as in C++, so every
// write form is a Kairo error at the write: `=` and `op=` are SC071E, `++`
// is SC071E, `&` (and so an `@inout` argument) is SC069E. Reading the
// field, calling a method on the temporary itself or on its field
// (`gwc().c.bump()`, legal C++), and writing through a pointer (`->`) stay
// legal.

ffi "c++" import "byval.h"

struct S { var v: i32 }

class B {
    var s: S
    fn B(self) { self.s = S{v: 0} }
    fn op [](self, i: usize) -> S { return self.s }
}

class C {
    var v: i32
    fn C(self) { self.v = 0 }
    fn bump(self) { self.v += 1 }
}

struct Outer { var s: S }

struct Wc { var c: C }

fn g() -> S { return S{v: 1} }
fn go() -> Outer { return Outer{s: S{v: 1}} }
fn gc() -> C { return C() }
fn gwc() -> Wc { return Wc{c: C()} }
fn inc(@inout x: i32) { x += 1 }

fn main() -> i32 {
    var b = B()
    var m = ByVal()
    g().v = 2
    b[0].v = 3
    m[0].v = 3
    go().s.v = 4
    S{v: 1}.v = 5
    g().v += 1
    g().v++
    var *p = &g().v
    inc(&g().v)
    gc().bump()
    gwc().c.bump()
    var r = g().v + b[0].v + go().s.v
    var local = S{v: 0}
    local.v = 6
    var *q = &local
    q->v = 7
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/temporary_field_write %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: temporary_field_write.k:40:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:41:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:42:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:43:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:44:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:45:5: error [SC071E]: left side of assignment is not assignable
// CHECK: temporary_field_write.k:46:5: error [SC071E]: '++'/'--' require an assignable operand
// CHECK: temporary_field_write.k:47:14: error [SC069E]: cannot take the address of a temporary
// CHECK: temporary_field_write.k:48:9: error [SC069E]: cannot take the address of a temporary
