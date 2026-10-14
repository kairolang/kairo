// A variant is built in place: the payload's initializers construct the
// payload fields directly inside the enum, so building one costs no copy and
// no move of the payload -- with no optimizer to remove them, and with one.
// Mv can only be moved and Cp's copy counts, so a transfer anywhere on the
// way shows. Each form a construction can take is checked: an explicit head
// on a generic and a non-generic enum, `.V` against a declared type, an
// argument, a return value, a nullary variant.
//
// Fields written out of declaration order whose initializers have effects
// are evaluated in the order written, into temporaries, and then moved into
// the payload: exactly one move per field, and the temporaries destroyed.

var copies: i32 = 0
var moves: i32 = 0
var drops: i32 = 0

class Cp {
    pub var id: i32
    pub fn Cp(self, id: i32) { self.id = id; }
    @copy fn Cp(self, const other: Self) { self.id = other.id; copies = copies + 1; }
    fn op delete(self) { drops = drops + 1; }
}

class Mv {
    pub var id: i32
    pub fn Mv(self, id: i32) { self.id = id; }
    @move fn Mv(self, other: Self) { self.id = other.id; moves = moves + 1; }
    fn op delete(self) { drops = drops + 1; }
}

enum <T> Slot { One { v: T }, Two { a: T, b: T }, Empty }
enum Pack { Both { c: Cp, m: Mv, n: i32 }, Neither }

fn reset() { copies = 0; moves = 0; drops = 0; }

fn none() -> bool { return (copies == 0) && (moves == 0) && (drops == 0) }

fn mk(n: i32) -> Mv { return Mv(n); }

fn by_value(s: Slot<Mv>) -> bool { return none() }
fn by_move(@move s: Slot<Mv>) -> bool { return none() }
fn made(n: i32) -> Slot<Mv> { return .Two { a: Mv(n), b: mk(n + 1) }; }

fn explicit_generic() -> bool {
    reset()
    var a = Slot<Cp>::One { v: Cp(1) }
    var b = Slot<Mv>::Two { a: Mv(2), b: mk(3) }
    return none()
}

fn explicit_plain() -> bool {
    reset()
    var p = Pack::Both { c: Cp(1), m: Mv(2), n: 3 }
    return none()
}

fn dotted() -> bool {
    reset()
    var a: Slot<Mv> = .One { v: Mv(1) }
    var e: Slot<Mv> = .Empty
    var n = Slot<Cp>::Empty
    return none()
}

fn argument() -> bool {
    reset()
    var ok = by_value(.One { v: Mv(1) })        // the parameter itself is built in place
    reset()
    return ok && by_move(Slot<Mv>::Two { a: Mv(2), b: Mv(3) })
}

fn returned() -> bool {
    reset()
    var r = made(1)
    return none()
}

fn out_of_order() -> bool {
    reset()
    var t = Slot<Mv>::Two { b: mk(2), a: mk(1) }
    return (copies == 0) && (moves == 2) && (drops == 2)
}

fn main() -> i32 {
    var r = 0
    if explicit_generic() { r += 1 }
    if explicit_plain()   { r += 2 }
    if dotted()           { r += 4 }
    if argument()         { r += 8 }
    if returned()         { r += 16 }
    if out_of_order()     { r += 32 }
    return r                                    // 63
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
// RUN: %kairo %s -c -O2 --cache-dir %t.o2
// RUN: %clangxx %t.o2/*.o %t.o2/builtin/*.o %t.o2/kairo/*.o -o %t.o2.exe
// RUN: %t.o2.exe; test $? -eq 63
