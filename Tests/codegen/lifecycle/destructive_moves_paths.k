// A move out of a local of a Kairo MOVE class is destructive
// (ownership.mdx, Moved-From State): the moved-from local is not
// destroyed at the end of its scope, and a local moved on some paths only
// is destroyed on the others. Res's move zeroes its source, so a
// moved-from object that is still destroyed prints `~Res 0`, and one that
// is never destroyed is a missing `~Res N`: every object here is
// destroyed exactly once, and no `~Res 0` is printed.
//  - branch / both / arms / logic / logic_or / if_value: moved on some
//    paths of an `if`, a `match`, `&&`, `||` or an `if` expression;
//  - rebuild / break_after / continue_after / labelled: loops;
//  - early / give / make: returns (`make` returns its only local, which
//    stays a plain C++ local);
//  - assign_dead / assign_maybe / bump_self: an assignment after a move
//    builds the new value in place;
//  - shadowed / in_closure / in_generic / coalesce / named_arg.
//  - ended_or_given: a local `finally()` ends on one path and that is
//    returned on the other is moved out by the return, not destroyed.
//  - konst: a `const` local cannot be moved, so it stays a plain local.
// Not disarmed, as C++ does it: a local of a generic parameter's type
// (forward), `x = x` (self_assign), and a live local assigned a new value
// (assign_live: the temporary's moved-from object is destroyed).
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

fn take(r: Res) { println(f"took {r.id}") }

fn yes(r: Res) -> bool {
    println(f"yes {r.id}")
    return true
}

fn pick(c: bool) -> bool { return c }

fn consume(r: Res) -> i32 { return r.id }

fn opt_int(c: bool) -> i32? {
    if c {
        return 1
    }
    return null
}

fn two_r(x: i32, r: Res) { println(f"two_r {r.id} {x}") }

fn bump(r: Res) -> Res { return Res(r.id + 1) }

fn branch(c: bool) {
    var a = Res(1)
    if c {
        take(a)
    } else {
        println("kept 1")
    }
    println("branch end")
}

fn both(c: bool) {
    var a = Res(2)
    if c {
        take(a)
    } else {
        var b = a
        println("into b")
    }
    println("both end")
}

fn arms(k: i32) {
    var a = Res(3)
    match k {
        case 1 { take(a) }
        case 2 {
            var b = a
            println("arm 2")
        }
        default { println("arm default") }
    }
    println("arms end")
}

fn logic(c: bool) {
    var a = Res(4)
    if pick(c) && yes(a) {
        println("and true")
    }
    println("logic end")
}

fn logic_or(c: bool) {
    var a = Res(5)
    if pick(c) || yes(a) {
        println("or true")
    }
    println("or end")
}

fn if_value(c: bool) {
    var a = Res(6)
    var b = Res(60)
    var r = if (c) => (a) else => b
    println(f"chose {r.id}")
}

fn rebuild() {
    var a = Res(7)
    for i in 0..3 {
        take(a)
        a = Res(70 + i)
    }
    println("rebuild end")
}

fn break_after(n: i32) {
    var a = Res(8)
    for i in 0..3 {
        if i == n {
            take(a)
            break
        }
    }
    println("break end")
}

fn continue_after() {
    for i in 0..2 {
        var a = Res(90 + i)
        if i == 0 {
            take(a)
            continue
        }
        println(f"kept {a.id}")
    }
    println("continue end")
}

fn labelled() {
    var a = Res(10)
    var i = 0
    outer: while i < 2 {
        i += 1
        while true {
            take(a)
            break outer
        }
    }
    println("labelled end")
}

fn early(c: bool) -> i32 {
    var a = Res(11)
    if c {
        return 1
    }
    take(a)
    return 0
}

fn give(c: bool) -> Res {
    var a = Res(12)
    if c {
        take(a)
        return Res(120)
    }
    return a
}

fn make() -> Res {
    var a = Res(13)
    return a
}

fn assign_dead() {
    var a = Res(14)
    take(a)
    a = Res(140)
    println(f"dead {a.id}")
}

fn assign_maybe(c: bool) {
    var a = Res(15)
    if c {
        take(a)
    }
    a = Res(150)
    println(f"maybe {a.id}")
}

fn assign_live() {
    var a = Res(16)
    a = Res(160)
    println(f"live {a.id}")
}

fn bump_self() {
    var a = Res(25)
    a = bump(a)
    println(f"bumped {a.id}")
}

fn self_assign() {
    var a = Res(24)
    a = a
    println(f"self {a.id}")
}

fn shadowed() {
    var a = Res(17)
    if true {
        var a = Res(170)
        take(a)
    }
    take(a)
    println("shadow end")
}

fn in_closure() {
    var f = fn () {
        var a = Res(19)
        take(a)
        println("closure body")
    }
    f()
}

fn <T> in_generic(x: T) -> T {
    var a = Res(20)
    take(a)
    return x
}

fn <T> forward(x: T) {
    var y = x
    var z = y
}

fn coalesce(c: bool) {
    var a = Res(22)
    var v = opt_int(c) ?? consume(a)
    println(f"coalesce {v}")
}

fn named_arg() {
    var a = Res(23)
    two_r(r: a, x: 5)
    println("named end")
}

fn ended_or_given(c: bool) -> Res {
    var a = Res(26)
    if c {
        a.finally()
        return Res(260)
    }
    return a
}

fn konst() {
    const a = Res(27)
    println(f"const {a.id}")
}

fn main() -> i32 {
    branch(true)
    branch(false)
    println("--")
    both(true)
    both(false)
    println("--")
    arms(1)
    arms(2)
    arms(0)
    println("--")
    logic(true)
    logic(false)
    logic_or(true)
    logic_or(false)
    println("--")
    if_value(true)
    if_value(false)
    println("--")
    rebuild()
    break_after(1)
    break_after(5)
    continue_after()
    labelled()
    println("--")
    println(f"early {early(true)}")
    println(f"early {early(false)}")
    if true {
        var g = give(true)
        println(f"gave {g.id}")
    }
    if true {
        var g = give(false)
        println(f"gave {g.id}")
    }
    if true {
        var g = make()
        println(f"made {g.id}")
    }
    println("--")
    assign_dead()
    assign_maybe(true)
    assign_maybe(false)
    assign_live()
    bump_self()
    self_assign()
    println("--")
    shadowed()
    in_closure()
    println(f"generic {in_generic(7)}")
    forward(Res(21))
    coalesce(true)
    coalesce(false)
    named_arg()
    println("--")
    if true {
        var g = ended_or_given(true)
        println(f"got {g.id}")
    }
    if true {
        var g = ended_or_given(false)
        println(f"got {g.id}")
    }
    konst()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// The one diagnostic is the warning for `shadowed`'s inner `a`.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: warning [R048W]: declaration of 'a' hides an outer binding of the same type
// DIAG-NOT: {{error|warning}}

// Moved on every path: union storage with no hook (elided). Moved on some,
// or alive again at an exit: a `live` flag the move clears. An assignment
// after the move is a construction in place, which destroys first only
// when the local may still hold an object. A local only returned stays
// plain.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: void branch(bool c) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX: __attribute((cleanup(__kairo_ul_run)))
// CXX: (__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v))
// CXX-LABEL: void both(bool c) noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {
// CXX-NOT: cleanup
// CXX: static_cast< ::{{.*}}::Res &&>(__k_s_a.v)
// CXX-LABEL: give(bool c) noexcept {
// CXX: return(__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v));
// CXX-LABEL: make() noexcept {
// CXX: ::{{.*}}::Res a = ::{{.*}}::Res(13);
// CXX-LABEL: void assign_dead() noexcept {
// CXX-NOT: __kill
// CXX: ( ::new(static_cast<void *>(& __k_s_a.s.v), ::__kairo_ulp {
// CXX-LABEL: void assign_maybe(bool c) noexcept {
// CXX: (__k_s_a.__kill(), ::new(static_cast<void *>(& __k_s_a.s.v), ::__kairo_ulp {
// CXX-LABEL: void self_assign() noexcept {
// CXX: ::{{.*}}::Res a = ::{{.*}}::Res(24);
// CXX-LABEL: void named_arg() noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX-LABEL: ended_or_given(bool c) noexcept {
// CXX: return(__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v));
// CXX-LABEL: void konst() noexcept {
// CXX-NOT: __kairo_ul
// CXX: }

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      took 1
// OUT-NEXT: ~Res 1
// OUT-NEXT: branch end
// OUT-NEXT: kept 1
// OUT-NEXT: branch end
// OUT-NEXT: ~Res 1
// OUT-NEXT: --
// OUT-NEXT: took 2
// OUT-NEXT: ~Res 2
// OUT-NEXT: both end
// OUT-NEXT: into b
// OUT-NEXT: ~Res 2
// OUT-NEXT: both end
// OUT-NEXT: --
// OUT-NEXT: took 3
// OUT-NEXT: ~Res 3
// OUT-NEXT: arms end
// OUT-NEXT: arm 2
// OUT-NEXT: ~Res 3
// OUT-NEXT: arms end
// OUT-NEXT: arm default
// OUT-NEXT: arms end
// OUT-NEXT: ~Res 3
// OUT-NEXT: --
// OUT-NEXT: yes 4
// OUT-NEXT: ~Res 4
// OUT-NEXT: and true
// OUT-NEXT: logic end
// OUT-NEXT: logic end
// OUT-NEXT: ~Res 4
// OUT-NEXT: or true
// OUT-NEXT: or end
// OUT-NEXT: ~Res 5
// OUT-NEXT: yes 5
// OUT-NEXT: ~Res 5
// OUT-NEXT: or true
// OUT-NEXT: or end
// OUT-NEXT: --
// OUT-NEXT: chose 6
// OUT-NEXT: ~Res 6
// OUT-NEXT: ~Res 60
// OUT-NEXT: chose 60
// OUT-NEXT: ~Res 60
// OUT-NEXT: ~Res 6
// OUT-NEXT: --
// OUT-NEXT: took 7
// OUT-NEXT: ~Res 7
// OUT-NEXT: took 70
// OUT-NEXT: ~Res 70
// OUT-NEXT: took 71
// OUT-NEXT: ~Res 71
// OUT-NEXT: rebuild end
// OUT-NEXT: ~Res 72
// OUT-NEXT: took 8
// OUT-NEXT: ~Res 8
// OUT-NEXT: break end
// OUT-NEXT: break end
// OUT-NEXT: ~Res 8
// OUT-NEXT: took 90
// OUT-NEXT: ~Res 90
// OUT-NEXT: kept 91
// OUT-NEXT: ~Res 91
// OUT-NEXT: continue end
// OUT-NEXT: took 10
// OUT-NEXT: ~Res 10
// OUT-NEXT: labelled end
// OUT-NEXT: --
// OUT-NEXT: ~Res 11
// OUT-NEXT: early 1
// OUT-NEXT: took 11
// OUT-NEXT: ~Res 11
// OUT-NEXT: early 0
// OUT-NEXT: took 12
// OUT-NEXT: ~Res 12
// OUT-NEXT: gave 120
// OUT-NEXT: ~Res 120
// OUT-NEXT: gave 12
// OUT-NEXT: ~Res 12
// OUT-NEXT: made 13
// OUT-NEXT: ~Res 13
// OUT-NEXT: --
// OUT-NEXT: took 14
// OUT-NEXT: ~Res 14
// OUT-NEXT: dead 140
// OUT-NEXT: ~Res 140
// OUT-NEXT: took 15
// OUT-NEXT: ~Res 15
// OUT-NEXT: maybe 150
// OUT-NEXT: ~Res 150
// OUT-NEXT: ~Res 15
// OUT-NEXT: maybe 150
// OUT-NEXT: ~Res 150
// OUT-NEXT: ~Res 16
// OUT-NEXT: ~Res 0
// OUT-NEXT: live 160
// OUT-NEXT: ~Res 160
// OUT-NEXT: ~Res 25
// OUT-NEXT: bumped 26
// OUT-NEXT: ~Res 26
// OUT-NEXT: self 24
// OUT-NEXT: ~Res 24
// OUT-NEXT: --
// OUT-NEXT: took 170
// OUT-NEXT: ~Res 170
// OUT-NEXT: took 17
// OUT-NEXT: ~Res 17
// OUT-NEXT: shadow end
// OUT-NEXT: took 19
// OUT-NEXT: ~Res 19
// OUT-NEXT: closure body
// OUT-NEXT: took 20
// OUT-NEXT: ~Res 20
// OUT-NEXT: generic 7
// OUT-NEXT: ~Res 21
// OUT-NEXT: ~Res 0
// OUT-NEXT: ~Res 0
// OUT-NEXT: coalesce 1
// OUT-NEXT: ~Res 22
// OUT-NEXT: ~Res 22
// OUT-NEXT: coalesce 22
// OUT-NEXT: two_r 23 5
// OUT-NEXT: ~Res 23
// OUT-NEXT: named end
// OUT-NEXT: --
// OUT-NEXT: ~Res 26
// OUT-NEXT: got 260
// OUT-NEXT: ~Res 260
// OUT-NEXT: got 26
// OUT-NEXT: ~Res 26
// OUT-NEXT: const 27
// OUT-NEXT: ~Res 27
// OUT-EMPTY:
