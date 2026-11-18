// `x.finally()` ends a local; everything else about it is an error the
// checker reports (Compiler/Spec/Lowering.md#union-storage-locals): a use
// of the local after it on any path (SC303E, an assignment included), a
// second one on a path (SC304E), one on something that is not a local of
// this body (SC305E), and the cases not supported yet (SC116E). On a local
// whose type is trivially destroyed it does nothing (SC305W).
class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) { self.id = other.id }
    fn op finally(self) { }
    fn get(self) -> i32 { return self.id }
}

class Holder {
    var r: Res = Res(0)
    fn kill(self) { self.r.finally() }
}

var g: Res = Res(9)

fn use_after() -> i32 {
    var r = Res(1)
    r.finally()
    return r.get()
}

fn twice(c: bool) {
    var r = Res(2)
    if c { r.finally() }
    r.finally()
}

fn in_loop() {
    var r = Res(3)
    while true {
        r.finally()
    }
}

fn assign_after() {
    var r = Res(4)
    r.finally()
    r = Res(5)
}

fn param(p: Res) { p.finally() }

fn global() { g.finally() }

fn trivial() {
    var n: i32 = 3
    n.finally()
}

interface Getter { fn get(self) -> i32 }
fn <T impl Getter> generic(t: T) {
    var x = t
    x.finally()
}

fn closure() {
    var r = Res(6)
    var f = fn () { r.finally() }
}

fn in_finally() {
    var r = Res(7)
    finally { r.finally() }
}

fn for_init() {
    for var r = Res(8); r.get() < 0; r.id += 1 {
        r.finally()
    }
}

fn args() {
    var r = Res(10)
    r.finally(1)
}

fn as_value() {
    var r = Res(11)
    var f = r.finally
}

// Accepted: the operator spelling, and an object a move left behind.
fn ok() {
    var r = Res(12)
    r.op finally()
    var s = Res(13)
    var q = s
    s.finally()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: finally_errors.k:17:21: error [SC305E]: finally() has no effect on 'self.r'; only a local variable declared in this body can be ended early
// CHECK: finally_errors.k:25:12: error [SC303E]: use of finalized value 'r'
// CHECK: finally_errors.k:24:5: note [SC303N]: 'r' was finalized here; its destructor has run
// CHECK: finally_errors.k:31:5: error [SC304E]: 'r' already finalized
// CHECK: finally_errors.k:30:12: note [SC304N]: 'r' was finalized here, on a path that reaches this call
// CHECK: finally_errors.k:37:9: error [SC304E]: 'r' already finalized
// CHECK: finally_errors.k:37:9: note [SC304N]: 'r' was finalized here, on a path that reaches this call
// CHECK: finally_errors.k:47:20: error [SC305E]: finally() has no effect on 'p'; it is a parameter, which the caller destroys
// CHECK: finally_errors.k:47:10: note [I900N]: 'p' is declared here
// CHECK: finally_errors.k:49:15: error [SC305E]: finally() has no effect on 'g'; it is a global, destroyed when the program ends
// CHECK: finally_errors.k:20:1: note [I900N]: 'g' is declared here
// CHECK: finally_errors.k:53:5: warning [SC305W]: finally() has no effect on 'n'; its type 'i32' is trivially destroyed
// CHECK: finally_errors.k:64:21: error [SC305E]: finally() has no effect on 'r'; it is not declared by a 'var' or 'const' statement of this body (a closure's enclosing function, or a pattern, destroys it)
// CHECK: finally_errors.k:63:5: note [I900N]: 'r' is declared here
// CHECK: finally_errors.k:69:15: error [SC116E]: finally() on 'r': a call inside a 'finally' block is not supported yet
// CHECK: finally_errors.k:74:9: error [SC116E]: finally() on 'r': it is a C-style for's variable, which is not supported yet
// CHECK: finally_errors.k:80:5: error [SC001E]: 'finally()' takes no arguments
// CHECK: finally_errors.k:85:13: error [SC001E]: the destructor is called as 'x.finally()'; it is not a value
