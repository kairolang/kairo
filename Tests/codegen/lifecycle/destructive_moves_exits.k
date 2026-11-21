// Destructive moves and the exits a path can take before or after the
// move (ownership.mdx, Moved-From State): a panic, a C++ exception through
// an `@unwind` function, a `try` that catches, a later argument of the
// same call, and a generator destroyed while suspended. Res's move zeroes
// its source: a moved-from object that is still destroyed prints
// `~Res 0`, one that is never destroyed is a missing `~Res N`.
//  - panic_before / panic_after: a panicking call before or after the move.
//  - caught: the move inside a `try` body, the panic before it.
//  - arg_first / arg_last: the local and a panicking argument of one call,
//    in either order; named_first / named_last: the same with named
//    arguments, which C++ evaluates in parameter order.
//  - unwind_before / unwind_after: a C++ exception the checker does not
//    see; the local keeps its flag, so the hook decides.
//  - gen_moved / gen_alive: a generator abandoned after its first `yield`,
//    with the local moved before it or after it.
ffi "c++" import "destructive_moves_exits.hh"
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

fn may(x: i32) panic -> i32 {
    if x > 0 {
        panic "boom"
    }
    return x
}

fn two(r: Res, x: i32) { println(f"two {r.id} {x}") }

fn two_r(x: i32, r: Res) { println(f"two_r {r.id} {x}") }

fn panic_before(x: i32) panic {
    var a = Res(30)
    var v = may(x)
    take(a)
    println(f"v {v}")
}

fn panic_after(x: i32) panic {
    var a = Res(31)
    take(a)
    var v = may(x)
    println(f"v {v}")
}

fn caught(x: i32) {
    var a = Res(32)
    try {
        var v = may(x)
        take(a)
    } catch {
        println("caught")
    }
    println("caught end")
}

fn arg_first(x: i32) panic {
    var a = Res(40)
    two(a, may(x))
}

fn arg_last(x: i32) panic {
    var a = Res(41)
    two_r(may(x), a)
}

fn named_first(x: i32) panic {
    var a = Res(42)
    two_r(r: a, x: may(x))
}

fn named_last(x: i32) panic {
    var a = Res(43)
    two(x: may(x), r: a)
}

@unwind fn unwind_before(x: i32) -> i32 {
    var a = Res(50)
    var v = dm_checked(x)
    take(a)
    return v
}

@unwind fn unwind_after(x: i32) -> i32 {
    var a = Res(51)
    take(a)
    return dm_checked(x)
}

fn gen_moved() -> yield i32 {
    var a = Res(60)
    take(a)
    yield 1
    yield 2
}

fn gen_alive() -> yield i32 {
    var a = Res(61)
    yield 1
    take(a)
    yield 2
}

fn first_of_moved() {
    for v in gen_moved() {
        println(f"got {v}")
        break
    }
}

fn first_of_alive() {
    for v in gen_alive() {
        println(f"got {v}")
        break
    }
}

fn all_of_alive() {
    for v in gen_alive() {
        println(f"got {v}")
    }
}

fn main() -> i32 {
    try { panic_before(1) } catch { println("c before") }
    try { panic_before(0) } catch { println("c before") }
    try { panic_after(1) } catch { println("c after") }
    try { panic_after(0) } catch { println("c after") }
    println("--")
    caught(1)
    caught(0)
    println("--")
    try { arg_first(1) } catch { println("c arg_first") }
    try { arg_first(0) } catch { println("c arg_first") }
    try { arg_last(1) } catch { println("c arg_last") }
    try { arg_last(0) } catch { println("c arg_last") }
    try { named_first(1) } catch { println("c named_first") }
    try { named_last(1) } catch { println("c named_last") }
    println("--")
    println(f"u {dm_guard(unwind_before, -1)}")
    println(f"u {dm_guard(unwind_before, 2)}")
    println(f"u {dm_guard(unwind_after, -1)}")
    println(f"u {dm_guard(unwind_after, 3)}")
    println("--")
    first_of_moved()
    first_of_alive()
    all_of_alive()
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Moved before every exit the checker sees: elided. An `@unwind` function
// can be left where it does not see, so its local keeps the flag.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: panic_after(signed int x) noexcept {
// CXX: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {
// CXX-NOT: cleanup
// CXX: static_cast< ::{{.*}}::Res &&>(__k_s_a.v)
// CXX-LABEL: unwind_after(signed int x) {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_a {
// CXX: (__k_s_a.live = false, static_cast< ::{{.*}}::Res &&>(__k_s_a.s.v))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 30
// OUT-NEXT: c before
// OUT-NEXT: took 30
// OUT-NEXT: ~Res 30
// OUT-NEXT: v 0
// OUT-NEXT: took 31
// OUT-NEXT: ~Res 31
// OUT-NEXT: c after
// OUT-NEXT: took 31
// OUT-NEXT: ~Res 31
// OUT-NEXT: v 0
// OUT-NEXT: --
// OUT-NEXT: caught
// OUT-NEXT: caught end
// OUT-NEXT: ~Res 32
// OUT-NEXT: took 32
// OUT-NEXT: ~Res 32
// OUT-NEXT: caught end
// OUT-NEXT: --
// OUT-NEXT: ~Res 40
// OUT-NEXT: c arg_first
// OUT-NEXT: two 40 0
// OUT-NEXT: ~Res 40
// OUT-NEXT: ~Res 41
// OUT-NEXT: c arg_last
// OUT-NEXT: two_r 41 0
// OUT-NEXT: ~Res 41
// OUT-NEXT: ~Res 42
// OUT-NEXT: c named_first
// OUT-NEXT: ~Res 43
// OUT-NEXT: c named_last
// OUT-NEXT: --
// OUT-NEXT: ~Res 50
// OUT-NEXT: u -1
// OUT-NEXT: took 50
// OUT-NEXT: ~Res 50
// OUT-NEXT: u 2
// OUT-NEXT: took 51
// OUT-NEXT: ~Res 51
// OUT-NEXT: u -1
// OUT-NEXT: took 51
// OUT-NEXT: ~Res 51
// OUT-NEXT: u 3
// OUT-NEXT: --
// OUT-NEXT: took 60
// OUT-NEXT: ~Res 60
// OUT-NEXT: got 1
// OUT-NEXT: got 1
// OUT-NEXT: ~Res 61
// OUT-NEXT: got 1
// OUT-NEXT: took 61
// OUT-NEXT: ~Res 61
// OUT-NEXT: got 2
// OUT-EMPTY:
