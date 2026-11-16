// A local of a panicking function, returned by name, moves into the result
// as it does from a function that cannot panic: a move-only local compiles,
// with its type inferred (`one`) or written (`one_typed`). A `panic e` of a
// local that leaves the function moves it too (`three`). What is not the
// body's own local is read, not moved: a closure returning the variable it
// captures (`four`, `outer`).
struct E { var c: i32 }
var copies: i32 = 0
class Big {
    pub var id: i32
    pub fn Big(self, id: i32) { self.id = id; }
    @move fn Big(self, other: Self) { self.id = other.id; }
    fn op finally(self) { }
}
class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
    fn op finally(self) { }
}
fn one(f: bool) panic(E) -> Big {
    if f { panic E { c: 1 } }
    var b = Big(2)
    return b
}
fn one_typed(f: bool) panic(E) -> Big {
    if f { panic E { c: 1 } }
    var b: Big = Big(3)
    return b
}
fn three(f: bool) panic(Big) -> i32 {
    var thrown = Big(5)
    if f { panic thrown }
    return 0
}
fn four() -> i32 {
    var outer = Cp(6)
    var get = fn () panic(E) -> Cp { return outer }
    var d = try get() catch => Cp(0)
    return outer.id + d.id
}
fn main() -> i32 {
    var a = try one(false) catch => Big(0)
    if a.id != 2 { return 1 }
    var b = try one_typed(false) catch => Big(0)
    if b.id != 3 { return 2 }
    try { three(true) } catch x: Big { if x.id != 5 { return 3 } }
    copies = 0
    if four() != 12 { return 4 }
    if copies == 0 { return 5 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s --print-ir -c -o /dev/null --emit-scope=inputs | %FileCheck %s --implicit-check-not='&&>(outer)'
// CHECK-DAG: static_cast< ::return_local_move::Big &&>(b)
// CHECK-DAG: static_cast< ::return_local_move::Big &&>(thrown)
