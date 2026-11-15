// A C++ exception through an `@unwind` function that holds a local
// `finally()` ends (Compiler/Spec/Lowering.md#union-storage-locals). The
// exception leaves at a point the checker does not see, so such a local
// always carries its `live` flag: the cleanup hook runs on the unwind, and
// the flag keeps it from destroying an object `finally()` already ended.
//  - fin_then_throw: ended, then the throw: one destructor call, before.
//  - throw_alive:    the throw with the object alive: one, on the unwind.
//  - no_finally:     no `finally()` at all: one, on the unwind (plain C++).
//  - caught:         a `noexcept` function whose `try` catches the C++
//                    exception: the local inside it is left by the throw,
//                    which the checker does not see either, so it is
//                    flagged too and destroyed once.
ffi "c++" import "finally_unwind.hh"
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    fn op finally(self) { println(f"~Res {self.id}") }
}

@unwind fn fin_then_throw(x: i32) -> i32 {
    var r = Res(1)
    r.finally()
    return checked(x)
}

@unwind fn throw_alive(x: i32) -> i32 {
    var r = Res(2)
    if x > 100 {
        r.finally()
    }
    return checked(x)
}

@unwind fn no_finally(x: i32) -> i32 {
    var r = Res(3)
    return checked(x)
}

fn caught(x: i32) -> i32 {
    try {
        var r = Res(4)
        var v = checked(x)
        r.finally()
        return v
    } catch e: cxx::std::exception {
        return -2
    }
}

fn main() -> i32 {
    println(f"e {caught(-1)}")
    println(f"a {guard(fin_then_throw, -1)}")
    println(f"b {guard(throw_alive, -1)}")
    println(f"c {guard(no_finally, -1)}")
    println(f"d {guard(throw_alive, 5)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: signed int fin_then_throw(signed int x) {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {
// CXX: __attribute((cleanup(__kairo_ul_run)))
// CXX-LABEL: signed int caught(signed int x) noexcept {
// CXX: ::__kairo_ulf< ::{{.*}}::Res> __k_s_r {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 4
// OUT-NEXT: e -2
// OUT-NEXT: ~Res 1
// OUT-NEXT: a -1
// OUT-NEXT: ~Res 2
// OUT-NEXT: b -1
// OUT-NEXT: ~Res 3
// OUT-NEXT: c -1
// OUT-NEXT: ~Res 2
// OUT-NEXT: d 5
// OUT-EMPTY:
