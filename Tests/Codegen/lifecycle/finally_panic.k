// A panic is a return (Compiler/Spec/Panic.md): an exit of every block it
// leaves. A local some `finally()` ends after a call that may panic is
// alive on the panic's path, so its storage is flagged and the panic path
// destroys it once; the normal path destroys it at the `finally()`.
// Through a call, inside a `try` with a Kairo arm, and through a
// panicking user operator.
import std::io::println

struct Bad { var n: i32 }

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    fn op finally(self) { println(f"~Res {self.id}") }
}

class Num {
    var v: i32 = 0
    fn Num(self, v: i32) { self.v = v }
    fn op +(const self, const o: Num) panic(Bad) -> Num {
        if o.v < 0 { panic Bad { n: o.v } }
        return Num(self.v + o.v)
    }
}

fn may(x: i32) panic(Bad) -> i32 {
    if x < 0 { panic Bad { n: x } }
    return x
}

fn through_call(x: i32) panic(Bad) -> i32 {
    var r = Res(1)
    var v = may(x)
    r.finally()
    return v
}

fn in_try(x: i32) -> i32 {
    try {
        var r = Res(2)
        var v = may(x)
        r.finally()
        return v
    } catch e: Bad {
        return e.n * 10
    }
}

fn through_op(x: i32) panic(Bad) -> i32 {
    var r = Res(3)
    var s = Num(1) + Num(x)
    r.finally()
    return s.v
}

fn main() -> i32 {
    var a = try through_call(-1) catch e: Bad => e.n
    println(f"a {a}")
    var b = try through_call(4) catch e: Bad => e.n
    println(f"b {b}")
    println(f"c {in_try(-2)}")
    println(f"d {in_try(5)}")
    var e = try through_op(-3) catch e: Bad => e.n
    println(f"e {e}")
    var f = try through_op(6) catch e: Bad => e.n
    println(f"f {f}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: through_call(signed int x) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {
// CXX-LABEL: in_try(signed int x) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {
// CXX-LABEL: through_op(signed int x) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 1
// OUT-NEXT: a -1
// OUT-NEXT: ~Res 1
// OUT-NEXT: b 4
// OUT-NEXT: ~Res 2
// OUT-NEXT: c -20
// OUT-NEXT: ~Res 2
// OUT-NEXT: d 5
// OUT-NEXT: ~Res 3
// OUT-NEXT: e -3
// OUT-NEXT: ~Res 3
// OUT-NEXT: f 7
// OUT-EMPTY:
