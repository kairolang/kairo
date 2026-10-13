// The special members of an ADT run exactly the payload transfers and
// destructions C++ would for a struct holding the live variant, and nothing
// for a variant that is not live. Cp counts its copies, Mv its moves, both
// their destructions; each case resets the counters, does one thing and
// checks the three counts exactly, so a payload copied where it should be
// moved, destroyed twice, or never destroyed shows as a missing bit in the
// exit code.
//
// A class has one transfer constructor, so no one payload can count both:
// Cp's @copy body is also what C++ runs to move it (a COPY type's move is
// its copy), and Mv cannot be copied. A moved-from payload is still
// destroyed, so a moving assignment from a temporary counts the temporary's
// destruction too.

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

fn reset() { copies = 0; moves = 0; drops = 0; }

fn seen(c: i32, m: i32, d: i32) -> bool {
    return (copies == c) && (moves == m) && (drops == d)
}

fn id_of(const s: Slot<Cp>) -> i32 {
    return match s {
        case .One(const v)        => v.id
        case .Two(const a, const b) => a.id * 10 + b.id
        case .Empty               => 0
    }
}

// Returning a `@move` parameter moves it into the result.
fn relay(@move s: Slot<Mv>) -> Slot<Mv> { return s; }
fn relay_cp(@move s: Slot<Cp>) -> Slot<Cp> { return s; }

fn copy_construct() -> bool {
    var a = Slot<Cp>::Two { a: Cp(1), b: Cp(2) }
    reset()
    var b = a                                   // both payload fields copied
    return seen(2, 0, 0) && (id_of(b) == 12)
}

fn move_construct() -> bool {
    var m = Slot<Mv>::One { v: Mv(1) }
    reset()
    var n = relay(m)
    var ok = seen(0, 1, 0)
    var c = Slot<Cp>::One { v: Cp(2) }
    reset()
    var d = relay_cp(c)                         // the move of a COPY payload is its copy
    return ok && seen(1, 0, 0) && (id_of(d) == 2)
}

fn same_tag_copy_assign() -> bool {
    var a = Slot<Cp>::One { v: Cp(1) }
    var b = Slot<Cp>::One { v: Cp(2) }
    reset()
    b = a                                       // b's payload destroyed, a's copied in
    return seen(1, 0, 1) && (id_of(b) == 1)
}

fn cross_tag_copy_assign() -> bool {
    var a = Slot<Cp>::One { v: Cp(1) }
    var t = Slot<Cp>::Two { a: Cp(2), b: Cp(3) }
    var e: Slot<Cp> = .Empty
    var z: Slot<Cp> = .Empty
    reset()
    t = a                                       // two destroyed, one copied
    var ok = seen(1, 0, 2) && (id_of(t) == 1)
    reset()
    e = a                                       // nothing to destroy, one copied
    ok = ok && seen(1, 0, 0) && (id_of(e) == 1)
    reset()
    a = z                                       // one destroyed, nothing copied
    return ok && seen(0, 0, 1) && (id_of(a) == 0)
}

fn same_tag_move_assign() -> bool {
    var b = Slot<Mv>::One { v: Mv(5) }
    reset()
    b = Slot<Mv>::One { v: Mv(6) }              // b's destroyed, moved in, the temporary's destroyed
    return seen(0, 1, 2)
}

fn cross_tag_move_assign() -> bool {
    var b = Slot<Mv>::One { v: Mv(1) }
    var e: Slot<Mv> = .Empty
    reset()
    b = Slot<Mv>::Empty                         // b's destroyed; the temporary holds nothing
    var ok = seen(0, 0, 1)
    reset()
    e = Slot<Mv>::One { v: Mv(2) }
    ok = ok && seen(0, 1, 1)
    reset()
    e = Slot<Mv>::Two { a: Mv(3), b: Mv(4) }    // one destroyed, two moved, two in the temporary
    return ok && seen(0, 2, 3)
}

fn self_assign() -> bool {
    var a = Slot<Cp>::One { v: Cp(1) }
    var t = Slot<Cp>::Two { a: Cp(2), b: Cp(3) }
    reset()
    a = a
    t = t
    return seen(0, 0, 0) && (id_of(a) == 1) && (id_of(t) == 23)
}

fn scope() {
    var a = Slot<Cp>::One { v: Cp(1) }
    var t = Slot<Cp>::Two { a: Cp(2), b: Cp(3) }
    var e: Slot<Cp> = .Empty
    var m = Slot<Mv>::Two { a: Mv(4), b: Mv(5) }
}

fn scope_exit() -> bool {
    reset()
    scope()                                     // built in place, then five payloads destroyed
    return seen(0, 0, 5)
}

fn main() -> i32 {
    var r = 0
    if copy_construct()        { r += 1 }
    if move_construct()        { r += 2 }
    if same_tag_copy_assign()  { r += 4 }
    if cross_tag_copy_assign() { r += 8 }
    if same_tag_move_assign()  { r += 16 }
    if cross_tag_move_assign() { r += 32 }
    if self_assign()           { r += 64 }
    if scope_exit()            { r += 128 }
    return r                                    // 255
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 255
