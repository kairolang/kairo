// `[T]` -> `std::vector<T>` both ways, for `i32`, `string` and a move-only
// type that counts its live objects and its moves. `into_cxx()` moves every
// element out and leaves the Kairo vector empty; `as` copies each element
// and leaves the source as it was. The way back is the vector's
// `ElemRange` constructor (a copy) or a move per element. A C++ element
// type that can be copied is still moved by `into_cxx()`. Afterwards no
// object is left alive.

ffi "c++" import "string"
ffi "c++" import "vector"

import std::io

var checks:   u64 = 0
var failures: u64 = 0
var live:     i64 = 0
var moves:    i64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

/// Move-only: no copy(), no copy constructor.
class Tok {
    pub var id: i64

    pub fn Tok(self, id: i64) {
        self.id = id
        live += 1
    }

    @move pub fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = -1
        live  += 1
        moves += 1
    }

    pub fn op finally(self) {
        live -= 1
    }
}

fn ints() {
    var v = Vector<i32>()
    for var i: i32 = 0; i < 1000; ++i {
        v.push(i * 7)
    }

    var c = v as cxx::std::vector<i32>
    ck(c.size() == 1000 && v.size() == 1000, "i32 as: sizes")
    ck(c[999] == 6993 && v[999] == 6993, "i32 as: elements")
    var cap = v.capacity()
    var m = v.into_cxx()
    ck(m.size() == 1000 && m[500] == 3500, "i32 into_cxx: elements")
    ck(v.size() == 0 && v.capacity() == cap, "i32 into_cxx: source empty, block kept")
    var back = Vector<i32>(m)
    ck(back.size() == 1000 && back[1] == 7, "i32 back")
    var e = Vector<i32>()
    ck(e.into_cxx().size() == 0 && (e as cxx::std::vector<i32>).size() == 0, "i32 empty")
    var one = Vector<i32>()
    one.push(5)
    var o = one.into_cxx()
    ck(o.size() == 1 && o[0] == 5, "i32 one")
}

fn strings() {
    var v = Vector<string>()
    for var i: i32 = 0; i < 50; ++i {
        v.push(f"element number {i} of the strings")
    }

    v.push("lit")
    var c = v as cxx::std::vector<string>
    ck(c.size() == 51 && v.size() == 51, "string as: sizes")
    ck(c[7] == "element number 7 of the strings" && v[7] == c[7], "string as: equal")
    ck(c[50] == "lit", "string as: literal")
    var m = v.into_cxx()
    ck(v.size() == 0, "string into_cxx: source empty")
    ck(m.size() == 51 && m[49] == "element number 49 of the strings", "string into_cxx: elements")
    var back = Vector<string>(m)
    ck(back.size() == 51 && back[3] == "element number 3 of the strings", "string back")
}

// COMPILER-WORKAROUND(move-through-foreign-pointer): `move(*(d + i))` with
// `d` from `m.data()` in the caller is copied, not moved; through a
// parameter it moves.
fn take_all(out: *Vector<Tok>, d: unsafe *Tok, n: usize) {
    unsafe {
        for var i: usize = 0; i < n; ++i {
            out->push(move(*(d + i)))
        }
    }
}

fn toks() {
    var v = Vector<Tok>()
    for var i: i64 = 0; i < 100; ++i {
        v.push(Tok(i))
    }

    ck(live == 100, "tok: 100 live")
    var before = moves
    var m = v.into_cxx()
    ck(moves - before == 100, "tok into_cxx: one move per element")
    ck(live == 100, "tok into_cxx: still 100 live")
    ck(v.size() == 0 && m.size() == 100 && m[42].id == 42, "tok into_cxx: elements")
    var back = Vector<Tok>()
    unsafe {
        take_all(&back, m.data() as unsafe *Tok, m.size())
    }

    m.clear()
    ck(live == 100, "tok back: 100 live")
    ck(back[99].id == 99, "tok back: elements")
}

/// A C++ element type with a copy constructor is moved too: the long
/// string keeps its heap buffer.
fn cxx_strings() {
    var v = Vector<cxx::std::string>()
    v.push(cxx::std::string("a C++ string far too long for the small buffer"))
    v.push(cxx::std::string("short"))
    var unsafe *before = v[0].data()
    var c = v.into_cxx()
    var unsafe *after = c[0].data()
    ck(before == after && c[0].size() == 46 && c[1].size() == 5, "std::string into_cxx: buffer kept")
}

fn main() -> i32 {
    ints()
    cxx_strings()
    strings()
    toks()
    ck(live == 0, "no object left")
    io::println(f"vector interop: checks={checks} failures={failures} live={live}")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new -O2 %s -o %t.o2.exe --cache-dir %t.d2
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: vector interop: checks=21 failures=0 live=0
