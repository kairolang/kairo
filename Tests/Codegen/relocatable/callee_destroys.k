// A by-value parameter of a `@relocatable` type is destroyed by the function
// that receives it, not by its caller. Move tracking and destructor
// placement agree with that: however a move-only relocatable value travels,
// the resource it owns is released exactly once, in the function that last
// held it, and a moved-from parameter releases nothing.
//
// `Res` counts every construction, move and destructor call; `freed` is a
// destructor that found the resource still owned.
//  - chain:   by value through three calls; the last one releases it.
//  - onward:  a parameter moved on is released by the function it went to.
//  - dropped: a parameter never used is released when its function returns,
//             before the caller's next statement.
//  - closure: a parameter a closure captures is released with the closure.
//  - panic:   a panic through the function that holds it releases it once.
//  - unwind:  so does a C++ exception through an `@unwind` function.
//  - temp:    a temporary argument is built in place and released by the
//             callee, with no move.
//  - reads:   a function that only reads the parameter still destroys it,
//             so it is not inferred `const`: a call whose result is unused
//             and two calls that could be merged each release their value.
ffi "c++" import "callee_destroys.hh"
import std::io::println

static made:  i32 = 0
static moved: i32 = 0
static freed: i32 = 0
static dtors: i32 = 0

struct Bad { var n: i32 }

@relocatable
class Res {
    pub var id:  i32
    pub var pad: usize

    pub fn Res(self, id: i32) {
        self.id  = id
        self.pad = 0
        made += 1
    }

    @move pub fn Res(self, other: Self) {
        self.id  = other.id
        self.pad = other.pad
        other.id = 0
        moved += 1
    }

    pub fn op finally(self) {
        dtors += 1
        if self.id != 0 {
            freed += 1
            println(f"  free {self.id}")
        }
    }
}

fn report(const what: string) {
    println(f"{what}: made {made} moved {moved} freed {freed} dtors {dtors}")
    made  = 0
    moved = 0
    freed = 0
    dtors = 0
}

@no_inline fn third(r: Res) -> i32 {
    println("  third holds it")
    return r.id
}

@no_inline fn second(r: Res) -> i32 {
    var v = third(r)
    println("  second after third")
    return v
}

@no_inline fn first(r: Res) -> i32 {
    var v = second(r)
    println("  first after second")
    return v
}

@no_inline fn peek(r: Res) -> i32 {
    return r.id
}

@no_inline fn dropped(r: Res) {
    println("  dropped ignores it")
}

@no_inline fn captured(r: Res) -> i32 {
    var f = fn () -> i32 {
        return r.id
    }

    var v = f()
    println("  captured called the closure")
    return v
}

@no_inline fn may(r: Res, x: i32) panic(Bad) -> i32 {
    if x < 0 {
        panic Bad { n: x }
    }

    return r.id + x
}

@unwind @no_inline fn hold(r: Res, x: i32) -> i32 {
    return checked(x) + r.id
}

@unwind fn through(x: i32) -> i32 {
    return hold(Res(6), x)
}

fn main() -> i32 {
    var r = Res(1)
    var a = first(r)
    println("  main after first")
    report(f"chain {a}")

    var b = third(Res(2))
    report(f"temp {b}")

    var d = Res(3)
    dropped(d)
    println("  main after dropped")
    report("dropped")

    var c = captured(Res(4))
    report(f"closure {c}")

    var p = try may(Res(5), -1) catch e: Bad => e.n
    report(f"panic {p}")
    var q = try may(Res(5), 2) catch e: Bad => e.n
    report(f"no panic {q}")

    var u = guard(through, -1)
    report(f"unwind {u}")
    var w = guard(through, 4)
    report(f"no unwind {w}")

    var x = peek(Res(7)) + peek(Res(7))
    peek(Res(8))
    report(f"reads {x}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d/o2
// RUN: %t.o2.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// RUN: %kairo %s -funwind -o %t.unwind.exe --cache-dir %t.d/unwind
// RUN: %t.unwind.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:        third holds it
// OUT-NEXT:   free 1
// OUT-NEXT:   second after third
// OUT-NEXT:   first after second
// OUT-NEXT:   main after first
// OUT-NEXT: chain 1: made 1 moved 3 freed 1 dtors 3
// OUT-NEXT:   third holds it
// OUT-NEXT:   free 2
// OUT-NEXT: temp 2: made 1 moved 0 freed 1 dtors 1
// OUT-NEXT:   dropped ignores it
// OUT-NEXT:   free 3
// OUT-NEXT:   main after dropped
// OUT-NEXT: dropped: made 1 moved 1 freed 1 dtors 1
// OUT-NEXT:   captured called the closure
// OUT-NEXT:   free 4
// OUT-NEXT: closure 4: made 1 moved 1 freed 1 dtors 2
// OUT-NEXT:   free 5
// OUT-NEXT: panic -1: made 1 moved 0 freed 1 dtors 1
// OUT-NEXT:   free 5
// OUT-NEXT: no panic 7: made 1 moved 0 freed 1 dtors 1
// OUT-NEXT:   free 6
// OUT-NEXT: unwind -1: made 1 moved 0 freed 1 dtors 1
// OUT-NEXT:   free 6
// OUT-NEXT: no unwind 10: made 1 moved 0 freed 1 dtors 1
// OUT-NEXT:   free 7
// OUT-NEXT:   free 7
// OUT-NEXT:   free 8
// OUT-NEXT: reads 14: made 3 moved 0 freed 3 dtors 3

// The reader is not `const` in the emitted C++.
// RUN: %kairo %s --print-ir | %FileCheck %s --check-prefix=CXX
// CXX: __attribute((noinline)) signed int peek({{ *}}::{{.*}}::Res r) noexcept;
