// An `if` expression as an argument to an imported C++ overload set. Its
// arms are emitted as written, so when every arm is an lvalue of the
// expression's type the C++ conditional is an lvalue ([expr.cond]/5): it
// binds `const T&` and the callee copies. An arm that is a new value, or
// that converts to the join, makes the conditional a prvalue, which binds
// `T&&`. Sema records the overload C++ takes in each case, so the pass
// stays silent, and the program shows which one ran. The same lvalue is
// the object of a member call: const when an arm is.

ffi "c++" import "if_lvalue_arms.h"
ffi "c++" import "vector"

fn of_const(c: bool, const a: Cp, const b: Cp) -> i32 {
    return (if (c) => (a) else => b).which()        // 1: which() const
}

fn main() -> i32 {
    var s: Sink
    var a = Cp(1)
    var b = Cp(2)
    var c = true
    var r = 0

    s.take(if (c) => (a) else => b)                 // lvalues: const Cp&
    r = r * 10 + s.last
    s.take(if (c) => (a) else => Cp(3))             // one new value: Cp&&
    r = r * 10 + s.last
    s.take(if (!c) => (a) else if (c) => (b) else => a)
    r = r * 10 + s.last

    var i: i32 = 1
    const k: i32 = 3
    var small: i8 = 4
    s.num(if (c) => (i) else => k)                  // one const arm: const int&
    r = r * 10 + s.last
    s.num(if (c) => (i) else => 4)                  // a literal arm: int&&
    r = r * 10 + s.last
    s.num(if (c) => (i) else => small)              // a converted arm: int&&
    r = r * 10 + s.last
    if r != 121122 {
        return 1
    }

    // push_back(const T&) copies once and moves nothing; both arms stay
    // usable, since neither was moved from.
    var before = cp_copies()
    var moved  = cp_moves()
    var v: cxx::std::vector<Cp>
    v.reserve(4)
    v.push_back(if (c) => (a) else => b)
    if cp_copies() - before != 1 || cp_moves() != moved {
        return 2
    }

    if of_const(c, a, b) != 1 || (if (c) => (a) else => b).which() != 2 {
        return 3
    }

    return a.id + b.id + v[0].id - 4                // 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: I012W
// CHECK-NOT: error
// RUN: %t.exe
