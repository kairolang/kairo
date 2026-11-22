// Destructive moves (ownership.mdx, Moved-From State) through the
// expression forms that run an operand on some paths only, and the locals
// whose storage cannot take a disarmed move. Res's move zeroes its
// source: a moved-from object that is still destroyed prints `~Res 0`,
// one that is never destroyed is a missing `~Res N`.
//  - fallback: the local is the right operand of `??`, moved only when
//    the left is null; assigned again afterwards.
//  - optional: the argument of a `?.` call, moved only when the receiver
//    is not null.
// Kept as C++ makes them (the moved-from object is destroyed): a local of
// a constructor body, a C-style `for` variable, an `@align` local.
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Res {self.id}") }
}

class Sink {
    var n: i32 = 0
    fn Sink(self) { }
    fn eat(self, r: Res) { println(f"ate {r.id}") }
}

class Built {
    var id: i32 = 0
    fn Built(self, id: i32) {
        var t = Res(id)
        take(t)
        self.id = id
    }
}

fn take(r: Res) { println(f"took {r.id}") }

fn opt_res(c: bool) -> Res? {
    if c {
        return Res(700)
    }
    return null
}

fn make_sink(c: bool) -> Sink? {
    if c {
        return Sink()
    }
    return null
}

fn fallback(c: bool) {
    var a = Res(70)
    var r = opt_res(c) ?? a
    println(f"fallback {r.id}")
    a = Res(71)
    println(f"again {a.id}")
}

fn optional(c: bool) {
    var a = Res(72)
    var s? = make_sink(c)
    s?.eat(a)
    println("optional end")
}

fn in_ctor() {
    var b = Built(74)
    println(f"built {b.id}")
}

fn c_for() {
    var k = 0
    for var r = Res(75); k < 1; k += 1 {
        take(r)
        break
    }
    println("c_for end")
}

fn aligned() {
    @align(16) var a = Res(76)
    take(a)
    println("aligned end")
}

fn main() -> i32 {
    fallback(true)
    fallback(false)
    println("--")
    optional(true)
    optional(false)
    println("--")
    in_ctor()
    c_for()
    aligned()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The locals that cannot take union storage stay plain C++ locals.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: Built::Built(signed int id) noexcept {
// CXX-NEXT: ::{{.*}}::Res t = ::{{.*}}::Res(id);
// CXX-LABEL: void fallback(bool c) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX-LABEL: void c_for() noexcept {
// CXX: for( ::{{.*}}::Res r = ::{{.*}}::Res(75);
// CXX-LABEL: void aligned() noexcept {
// CXX-NEXT: __attribute((aligned(16)))::{{.*}}::Res a = ::{{.*}}::Res(76);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 0
// OUT-NEXT: ~Res 0
// OUT-NEXT: fallback 700
// OUT-NEXT: ~Res 70
// OUT-NEXT: again 71
// OUT-NEXT: ~Res 700
// OUT-NEXT: ~Res 71
// OUT-NEXT: fallback 70
// OUT-NEXT: again 71
// OUT-NEXT: ~Res 70
// OUT-NEXT: ~Res 71
// OUT-NEXT: --
// OUT-NEXT: ate 72
// OUT-NEXT: ~Res 72
// OUT-NEXT: optional end
// OUT-NEXT: optional end
// OUT-NEXT: ~Res 72
// OUT-NEXT: --
// OUT-NEXT: took 74
// OUT-NEXT: ~Res 74
// OUT-NEXT: ~Res 0
// OUT-NEXT: built 74
// OUT-NEXT: took 75
// OUT-NEXT: ~Res 75
// OUT-NEXT: ~Res 0
// OUT-NEXT: c_for end
// OUT-NEXT: took 76
// OUT-NEXT: ~Res 76
// OUT-NEXT: aligned end
// OUT-NEXT: ~Res 0
// OUT-EMPTY:
