// An imported overload set with a forwarding reference `U&&` beside a
// `const T&`. A forwarding reference deduces the argument's own type and
// kind ([temp.deduct.call]/3), so it binds a non-const lvalue as `T&` and
// an rvalue as `T&&`, each better than `const T&` ([over.ics.rank]/3.2.3,
// 3.2.6); only a const lvalue ties, and the tie goes to the non-template.
// std::pair's constructors are this set. Sema records the overload C++
// takes, so the pass stays silent, and the program shows which one ran.

ffi "c++" import "forwarding_reference.h"
ffi "c++" import "utility"

fn main() -> i32 {
    var   a: i32 = 1
    var   b: i32 = 2
    const k: i32 = 3
    var   r      = fwd(a) // 2: int&
    r = r * 10 + fwd(a + 1) // 2: int&&
    r = r * 10 + fwd(k)     // 1: a const lvalue ties
    r = r * 10 + fwd(7)     // 2: a literal is an rvalue
    r = r * 10 + ref(a + 1) // 2: no rvalue binds int&
    if r != 22122 {
        return 1
    }

    var t1 = Two<i32, i32>(a, b)
    var t2 = Two<i32, i32>(a + 1, b)
    var t3 = Two<i32, i32>(k, k)
    var t4 = Two<i32, i32>(a, k)
    if t1.which * 1000 + t2.which * 100 + t3.which * 10 + t4.which != 2212 {
        return 2
    }

    // The forwarding constructor copies an lvalue and moves an rvalue.
    var x       = Cp(5)
    var id: u32 = 3
    var p       = Two<u32, Cp>(id, x)
    if p.which != 2 || cp_copies() != 1 || cp_moves() != 0 {
        return 3
    }

    var q = Two<u32, Cp>(id, Cp(6))
    if q.which != 2 || cp_copies() != 1 || cp_moves() != 1 {
        return 4
    }

    var sp = cxx::std::pair<u32, i32>(id, a)
    var sq = cxx::std::pair<u32, i32>(id + 1, a)
    return (sp.first + sq.first) as i32 + x.id + p.second.id + q.second.id - 23 // 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: I012W
// CHECK-NOT: error
// RUN: %t.exe
