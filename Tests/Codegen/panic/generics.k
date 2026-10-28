// Panic sets in generic bodies, end to end (PANIC.md P10, MONO.md D0/D2):
// a generic body's set is computed at its definition and may name its type
// parameters; one C++ template serves every instance, its result
// `::__kairo_pset<Panic, T, E...>`, which C++ deduplicates and sorts by
// type id at each instance -- the canonical order a concrete caller's
// `Panic<T, E...>` has -- pinned by a static_assert against the result
// Sema predicted for each instance it sees. Run at -O0 and -O2. Covered:
//   bound      a call through `T impl Src<IOError>`: the requirement's
//              declared set, propagated (twice), caught (safe);
//   param      a set naming the bound's own parameter (through<E, T>);
//   nested     generic calling generic (outer -> twice);
//   collide    a set naming T beside A, used at T = B (two errors, sorted)
//              and at T = A (one: the two collapse);
//   forward    a tail call of a generic (the result forwarded whole), a
//              `try` of two sites catching T and letting A through, a
//              dependent set widened into a declared one, a qualified
//              requirement call (`Src<IOError>::read(f)`);
//   method     a generic class's method panicking with its T, a sibling
//              called through self, a generic conformer (Cell<T> impl
//              Src<T>);
//   slot       two sites in one `try` and a bare `catch` in a generic body,
//              a re-panic of the bare binding, of a move-only error owning
//              heap memory (`live` is 0 at the end: each destroyed once);
//   override   a generic base's virtual method, overridden at B, called
//              through the base.

ffi "c" import "stdlib.h"

var live: i32 = 0

class Big {
    var p: unsafe *i32
    pub fn Big(self, v: i32) {
        unsafe { self.p = malloc(4) as unsafe *i32 }
        (*self.p) = v
        live += 1
    }
    @move
    fn Big(self, other: Self) {
        self.p = other.p
        unsafe { other.p = &null }
        live += 1
    }
    fn op delete(self) {
        if self.p != &null { unsafe { free(self.p as unsafe *void) } }
        live -= 1
    }
    pub fn get(const self) -> i32 { return *self.p }
}

struct IOError { var code: i32 }
struct ParseError { var at: i32 }
struct A { var n: i32 }
struct B { var n: i32 }

interface <E> Src {
    fn read(self) panic(E) -> i32
}

class File impl Src<IOError> {
    pub var v: i32
    fn read(self) panic(IOError) -> i32 {
        if self.v < 0 { panic IOError { code: self.v } }
        return self.v
    }
}

fn <T impl Src<IOError>> twice(t: T) panic -> i32 {
    return t.read() + t.read()
}

fn <T impl Src<IOError>> safe(t: T) -> i32 {
    return try t.read() catch e: IOError => e.code
}

fn <E, T impl Src<E>> through(t: T) panic -> i32 {
    var a = t.read()
    if a > 100 { panic ParseError { at: a } }
    return a
}

fn <T impl Src<IOError>> outer(t: T) panic -> i32 {
    return twice(t) + 1
}

fn <T> pick(x: T, flag: bool) panic -> i32 {
    if flag { panic x }
    panic A { n: 7 }
}

fn <T> tail(x: T, f: bool) panic -> i32 { return pick(x, f) }

fn <T> part(x: T, y: T, f: i32) panic -> i32 {
    var r = 0
    try {
        r = pick(x, f == 1)
        r = r + pick(y, f == 2)
    } catch e: T {
        r = 100
    }
    return r
}

fn <T> wide(x: T, f: bool) panic(T, A, IOError) -> i32 {
    if !f { panic IOError { code: 1 } }
    return pick(x, f)
}

class <T> Cell impl Src<T> {
    pub var bad: bool
    pub var err: T
    fn read(self) panic(T) -> i32 {
        if self.bad { panic self.err }
        return 3
    }
    fn twice(self) panic -> i32 { return self.read() + self.read() }
}

class Maker impl Src<Big> {
    pub var v: i32
    fn read(self) panic(Big) -> i32 {
        if self.v < 0 { panic Big(self.v) }
        return self.v
    }
}

fn <T impl Src<Big>> both(t: T, u: T) -> i32 {
    var r = 0
    try {
        r = t.read()
        r = r + u.read()
    } catch e {
        r = -1
    }
    return r
}

fn <T impl Src<Big>> rethrow(t: T) panic -> i32 {
    try { return t.read() + 1 } catch e { panic e }
}

class <T> Base {
    virtual fn run(self, x: i32) panic(T, A) -> i32 { return x }
}
class Derived derives Base<B> {
    override fn run(self, x: i32) panic -> i32 {
        if x < 0 { panic B { n: x } }
        return x * 2
    }
}

fn main() -> i32 {
    var good = File { v: 2 }
    var bad = File { v: -7 }
    var big = File { v: 500 }
    if (try twice(good) catch e: IOError => -1) != 4 { return 1 }
    if (try twice(bad) catch e: IOError => e.code) != -7 { return 2 }
    if safe(bad) != -7 { return 3 }
    if (try through<IOError, File>(bad) catch e: IOError => e.code catch e: ParseError => e.at) != -7 { return 4 }
    if (try through<IOError, File>(big) catch e: IOError => e.code catch e: ParseError => e.at) != 500 { return 5 }
    if (try outer(bad) catch e: IOError => 100 + e.code) != 93 { return 6 }
    if (try outer(good) catch e: IOError => 100 + e.code) != 5 { return 7 }

    if (try pick(B { n: 1 }, true) catch e: A => e.n catch e: B => 100 + e.n) != 101 { return 10 }
    if (try pick(B { n: 1 }, false) catch e: A => e.n catch e: B => 100 + e.n) != 7 { return 11 }
    if (try pick(A { n: 2 }, true) catch e: A => e.n) != 2 { return 12 }
    if (try pick(A { n: 2 }, false) catch e: A => e.n) != 7 { return 13 }

    if (try tail(B { n: 1 }, true) catch e: A => 0 catch e: B => e.n) != 1 { return 14 }
    if (try tail(B { n: 1 }, false) catch e: A => e.n catch e: B => 0) != 7 { return 15 }
    if (try part(B { n: 1 }, B { n: 2 }, 1) catch e: A => e.n) != 100 { return 16 }
    if (try part(B { n: 1 }, B { n: 2 }, 3) catch e: A => e.n) != 7 { return 17 }
    if (try wide(B { n: 1 }, true) catch e: A => 0 catch e: B => e.n catch e: IOError => 50) != 1 { return 18 }
    if (try wide(B { n: 1 }, false) catch e: A => 0 catch e: B => e.n catch e: IOError => 50) != 50 { return 19 }
    if (try Src<IOError>::read(bad) catch e: IOError => e.code) != -7 { return 8 }

    var c = Cell<B> { bad: false, err: B { n: 8 } }
    var d = Cell<B> { bad: true, err: B { n: 8 } }
    if (try c.twice() catch e: B => -1) != 6 { return 20 }
    if (try d.twice() catch e: B => e.n) != 8 { return 21 }
    var m = Maker { v: 3 }
    var n = Maker { v: -4 }
    if both(m, m) != 6 { return 22 }
    if both(m, n) != -1 { return 23 }
    if both(n, m) != -1 { return 24 }
    if (try rethrow(n) catch e: Big => e.get()) != -4 { return 25 }
    if (try rethrow(m) catch e: Big => e.get()) != 4 { return 26 }
    if live != 0 { return 27 }

    var dv = Derived {}
    var bp: *Base<B> = &dv
    if (try bp->run(-3) catch e: B => e.n catch e: A => 100) != -3 { return 30 }
    if (try bp->run(5) catch e: B => e.n catch e: A => 100) != 10 { return 31 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d %t.o2 %t.ir
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2
// RUN: %t.o2.exe
// RUN: %kairo %s --print-ir -o %t.ir.exe --cache-dir %t.ir | %FileCheck %s --check-prefix=CXX
// The template's result is the alias over the set as written; each
// instance Sema saw is pinned to the canonical type it predicted, and its
// explicit instantiation spells that type. At T = A the two elements are one.
// CXX: ::__kairo_pset< ::builtin::types::Panic, signed int, ::generics::A, T> pick(T x, bool flag) noexcept;
// CXX-DAG: static_assert(__is_same(::__kairo_pset<::builtin::types::Panic, signed int,::generics::A,::generics::A>,::builtin::types::Panic<signed int,::generics::A>), "{{[^"]*}}");
// CXX-DAG: template::builtin::types::Panic<signed int,::generics::A>(::generics::pick<::generics::A>)(::generics::A, bool);
