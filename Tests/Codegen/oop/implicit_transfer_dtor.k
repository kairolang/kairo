// A record that writes a destructor and a constructor but no transfer
// constructor takes its category from its bases and fields
// (classes-lifecycle.mdx, "The transfer constructor"), and has that
// category's transfer and no other. C++ declares no implicit move beside a
// user-declared destructor, so:
//
//   COPY   nothing is declared: C++'s implicit copy is the transfer, and a
//          value handed on for the last time is copied, never emptied, so
//          the destructor of the source runs on an intact object.
//   MOVE   the move constructor and move assignment are declared
//          `= default`; the copy stays implicitly deleted.
//
// A generic record's category is its instance's: `Box<S>` copies and
// `Box<Mv>` moves, from one pattern.

ffi "c++" import "string"

var emptied: i32 = 0
var moves:   i32 = 0

class Mv {
    pub var n: i32 = 0
    fn Mv(self) { }
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) {
        self.n = other.n
        other.n = 0
        moves += 1
    }
}

// COPY: its one field copies. C++ would move the string out of a moved
// source and leave it empty.
class Cp {
    pub var v: cxx::std::string
    fn Cp(self, n: usize) { self.v.resize(n) }
    fn op finally(self) { if self.v.size() != 40 { emptied += 1 } }
}

class MvClass {
    pub var m: Mv
    fn MvClass(self, n: i32) { self.m = Mv(n) }
    fn op finally(self) { }
}

struct MvStruct {
    pub var m: Mv
    fn MvStruct(self, n: i32) { self.m = Mv(n) }
    fn op finally(self) { }
}

class <T> Box {
    pub var tag: cxx::std::string
    pub var v:   T
    fn Box(self, v: T) {
        self.v = v
        self.tag.resize(40)
    }
    fn op finally(self) { if self.tag.size() != 40 { emptied += 1 } }
}

class S {
    pub var k: i32 = 0
    fn S(self) { }
    fn S(self, k: i32) { self.k = k }
}

// Each takes its parameter by value: it writes to it, and leaves it at the
// length the destructor expects.
fn keep(c: Cp) -> usize {
    c.v.resize(41)
    var n = c.v.size()
    c.v.resize(40)
    return n
}

fn keep_box(b: Box<S>) -> usize {
    b.tag.resize(41)
    var n = b.tag.size()
    b.tag.resize(40)
    return n
}

fn take_class(h: MvClass) -> i32 {
    h.m.n += 1
    return h.m.n
}

fn take_struct(h: MvStruct) -> i32 {
    h.m.n += 1
    return h.m.n
}

fn take_box(b: Box<Mv>) -> i32 {
    b.v.n += 1
    return b.v.n
}

// The one expansion forwards its element: the last use of a temporary.
fn <...T> last_cp(...xs: T) -> usize { return keep(xs...) }
fn <...T> last_box(...xs: T) -> usize { return keep_box(xs...) }

fn main() -> i32 {
    if last_cp(Cp(40)) != 41 { return 1 }
    if emptied != 0 { return 2 }

    if last_box(Box<S>(S(1))) != 41 { return 3 }
    if emptied != 0 { return 4 }

    var c = Cp(40)
    var d = c
    if c.v.size() != 40 || d.v.size() != 40 { return 5 }

    var hc = MvClass(7)
    moves = 0
    if take_class(hc) != 8 { return 6 }
    if moves != 1 { return 7 }

    var hs = MvStruct(7)
    moves = 0
    if take_struct(hs) != 8 { return 8 }
    if moves != 1 { return 9 }

    var bm = Box<Mv>(Mv(7))
    moves = 0
    if take_box(bm) != 8 { return 10 }
    if moves != 1 { return 11 }

    var x = MvClass(1)
    var y = MvClass(2)
    x = y
    if x.m.n != 2 { return 12 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -A SC224W -A SC060W 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=CXX
// CXX: class Cp {
// CXX-NOT: Cp(Cp &&)
// CXX-NOT: Cp(const Cp &)
// CXX: class MvClass {
// CXX-NOT: MvClass(const MvClass &)
// CXX: MvClass(MvClass &&) = default;
// CXX-NEXT: MvClass & operator =(MvClass &&) = default;
// CXX-NEXT: };
// CXX: struct MvStruct {
// CXX-NOT: MvStruct(const MvStruct &)
// CXX: MvStruct(MvStruct &&) = default;
// CXX-NEXT: MvStruct & operator =(MvStruct &&) = default;
// CXX-NEXT: };
// CXX: template<class T> class Box {
// CXX: Box(const Box &) requires(__is_constructible(__remove_all_extents(T), const __remove_all_extents(T) &)) = default;
// CXX-NEXT: Box & operator =(const Box &) requires(__is_constructible(__remove_all_extents(T), const __remove_all_extents(T) &)) = default;
// CXX-NEXT: Box(Box &&) requires(!(__is_constructible(__remove_all_extents(T), const __remove_all_extents(T) &))) = default;
// CXX-NEXT: Box & operator =(Box &&) requires(!(__is_constructible(__remove_all_extents(T), const __remove_all_extents(T) &))) = default;
// CXX-NEXT: };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|C240W}}
// RUN: %t.exe
