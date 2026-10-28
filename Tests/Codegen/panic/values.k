// Panic results over value types other than i32 (PANIC.md §4.2): a
// nullable, a pointer, a record built in the Ok payload or moved there from
// a by-value parameter, a record through an expression `try`'s result slot;
// arms that `break` and `continue` a loop from inside the expression; and a
// `panic e` of a local into a `try`'s slot COPIES it (control goes on, and
// the local with it), where into the function's return it would move.
struct E { var c: i32 }
var copies: i32 = 0
var moves: i32 = 0
class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
    fn op delete(self) { }
}
class Big {
    pub var id: i32
    pub fn Big(self, id: i32) { self.id = id; }
    @move fn Big(self, other: Self) { self.id = other.id; moves = moves + 1; }
    fn op delete(self) { }
}
fn n1(f: bool) panic(E) -> i32? { if f { panic E { c: 1 } } return null }
fn n2() panic(E) -> i32? { return 3 }
var cell: i32 = 5
fn p1() panic(E) -> *i32 { return &cell }
fn r1(f: bool) panic(E) -> Big { if f { panic E { c: 2 } } return Big(1) }
fn r2(b: Big) panic(E) -> Big { return b }
fn local_copy() -> i32 {
    var e = Cp(4)
    try { panic e } catch x: Cp { if x.id != 4 { return 1 } }
    if e.id != 4 { return 2 }
    return 0
}
fn brk() -> i32 {
    var n = 0
    while n < 10 {
        n = n + 1
        var v = try r1(n == 3) catch => break
        if v.id != 1 { return 99 }
    }
    return n
}
fn cont() -> i32 {
    var hits = 0
    for var i: i32 = 0; i < 5; ++i {
        var v = try r1(i == 2) catch => continue
        hits = hits + v.id
    }
    return hits
}
fn main() -> i32 {
    var a = try n1(false) catch => 7
    if a? { return 1 }
    var b = try n2() catch => null
    if unwrap!(b) != 3 { return 2 }
    var c = try p1() catch => &cell
    if (*c) != 5 { return 3 }
    moves = 0
    var g = try r1(false) catch => Big(0)
    if g.id != 1 { return 4 }
    var h = try r2(Big(9)) catch => Big(0)
    if h.id != 9 { return 5 }
    if local_copy() != 0 { return 6 }
    if copies != 2 { return 7 }
    if brk() != 3 { return 8 }
    if cont() != 4 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
