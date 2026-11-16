// `x->m()` through a record's `operator->`. The member is called on what
// the operator's result points to, with that pointee's cv: a const
// iterator's `operator->` returns a pointer to const, so `m() const` is
// the overload ([over.ref]). A const object takes the `operator->() const`
// of a const / non-const pair. Sema records the overload C++ takes, so the
// pass stays silent, and the program shows which one ran.

ffi "c++" import "arrow_const_pointee.h"

fn through_const(const o: Opt) -> i32 {
    return o->which()
}

fn main() -> i32 {
    var t: Tab
    var ci = t.cbegin()
    var mi = t.begin()
    var o: Opt
    var r = ci->which()                             // 1: the pointee is const
    r = r * 10 + mi->which()                        // 2
    r = r * 10 + o->which()                         // 2
    r = r * 10 + through_const(o)                   // 1
    r = r * 10 + (*ci).which()                      // 1
    return r - 12211
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fsema-agreement -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --allow-empty
// CHECK-NOT: I012W
// CHECK-NOT: error
// RUN: %t.exe
