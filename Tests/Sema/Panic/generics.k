// Panic sets in generic bodies (PANIC.md P10, MONO.md D0/D5): a generic
// body's set is computed once, at its definition -- what it raises, its
// concrete callees' sets, and the DECLARED sets of the bound requirements
// it calls, read at the bound's arguments -- and is checked there like any
// other body. Nothing is inferred per instance; what only an instance can
// tell is checked at the instance's use.
//
// - a bound's requirement panics with its interface's parameter, read at
//   the bound (`T impl Src<E>`: the call panics with E) and unhandled;
// - a declared generic set: a type outside it is the usual error;
// - two arms that name one type at an instance (`catch e: T` beside
//   `catch e: A` at T = A): §3.1's duplicate arm, reported where the
//   instance is used, with the chain when a generic body reached it;
// - a recursion at ever-larger arguments: the set would grow forever;
// - a conformer of a generic interface is held to the requirement's set
//   at the row's arguments, and an override of a generic base to the
//   base's at the arguments it derives;
// - a STRUCTURAL conformance a bound finds (no `impl` declared) is held
//   to the requirement's set at the bound's arguments, at the use;
// - `pub` generic functions get the inferred-set lint too (--shared).

struct A { var n: i32 }
struct B { var n: i32 }
struct C { var n: i32 }
struct <T> Box { var v: T }

interface <E> Src {
    fn read(self) panic(E) -> i32
}

fn <E, T impl Src<E>> unhandled(t: T) -> i32 {
    return t.read()
}

fn <E, T impl Src<E>> declared(t: T, f: bool) panic(E) -> i32 {
    if f { panic A { n: 1 } }
    return t.read()
}

fn <T> boom(x: T, f: bool) panic -> i32 {
    if f { panic x }
    panic A { n: 9 }
}

fn <T> dup(x: T) -> i32 {
    return try boom(x, true) catch e: T => 1 catch e: A => 2
}

fn <U> via(x: U) -> i32 { return dup(x) }

fn <T> deep(x: T, n: i32) panic -> i32 {
    if n == 0 { panic x }
    return deep(Box<T> { v: x }, n - 1)
}

class Wide impl Src<A> {
    fn read(self) panic(A, B) -> i32 { return 1 }
}

class <T> Base {
    virtual fn run(self, x: i32) panic(T, A) -> i32 { return x }
}
class Derived derives Base<B> {
    override fn run(self, x: i32) panic(B, C) -> i32 { return x }
}

pub fn <T> lib(x: T) panic -> i32 { panic x }

fn main() -> i32 {
    var a = dup(B { n: 3 })
    var c = via(A { n: 4 })
    return a + c
}

class Loose {
    fn read(self) panic(A, B) -> i32 { panic B { n: 1 } }
}
fn <T impl Src<A>> through_loose(t: T) panic -> i32 { return t.read() }
fn structural() -> i32 { return try through_loose(Loose {}) catch e: A => e.n }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// RUN: { %kairo %s --type-check-only --shared 2>&1 || true; } | %FileCheck %s --check-prefix=LIB
// CHECK: generics.k:32:12: error [SC001E]: unhandled panic: 'read' may panic with 'E', and 'unhandled' is not marked 'panic'
// CHECK-NEXT: fix-it:"{{.*}}generics.k":{31:38-31:38}:" panic"
// CHECK-NEXT: generics.k:28:5: note [SC001N]: 'read' is declared 'panic' here
// CHECK-NEXT: generics.k:32:12: note [SC001N]: or handle it here
// CHECK-NEXT: fix-it:"{{.*}}generics.k":{32:12-32:12}:"try "
// CHECK-NEXT: fix-it:"{{.*}}generics.k":{32:20-32:20}:" catch => crash!()"
// CHECK: generics.k:36:12: error [SC001E]: 'A' is not in the declared panic set of 'declared'
// CHECK-NEXT: fix-it:"{{.*}}generics.k":{35:54-35:54}:", A"
// CHECK: generics.k:51:27: error [SC001E]: the panic set of 'deep' grows without bound: it calls itself (or a function that calls it) at ever-larger type arguments
// CHECK-NEXT: generics.k:51:1: note [SC001N]: a declared set, 'panic(E1, E2)', bounds it: what the recursive call panics with must then be in it or caught
// CHECK: generics.k:57:19: error [SC001E]: 'B' is not in the panic set of 'Src::read', which this implements; a conforming method's set must be a subset of it
// CHECK-NEXT: generics.k:28:5: note [SC001N]: 'Src::read' is declared here
// CHECK: generics.k:64:35: error [SC001E]: 'C' is not in the panic set of 'Base::run', which this overrides; an override's set must be a subset of it
// CHECK-NEXT: generics.k:61:5: note [SC001N]: 'Base::run' is declared here
// CHECK: generics.k:71:13: error [SC001E]: two 'catch' arms of one 'try' catch 'A' in 'dup<A>': the first takes every 'A', and the second never runs
// CHECK-NEXT: generics.k:46:39: note [SC001N]: this arm catches 'A' at these arguments
// CHECK-NEXT: generics.k:46:55: note [SC001N]: and so does this one
// CHECK-NEXT: generics.k:49:34: note [I900N]: in instantiation of 'dup<A>' required here
// CHECK: generics.k:79:37: error [SC001E]: 'Loose' does not meet 'Src<A>' here: 'B' is not in the panic set of 'Src::read', which 'Loose::read' implements
// CHECK-NEXT: generics.k:76:5: note [SC001N]: 'Loose::read' may panic with 'B'
// CHECK-NEXT: generics.k:28:5: note [SC001N]: 'Src::read' is declared here
// LIB: generics.k:67:22: warning [SC001W]: the panic set of public function 'lib' is inferred ('T'); declare it, or a change to the body changes its callers' contract
// LIB-NEXT: fix-it:"{{.*}}generics.k":{67:22-67:27}:"panic(T)"
