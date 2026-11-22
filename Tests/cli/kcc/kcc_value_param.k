// A by-value parameter of a destructive Kairo class (MOVE, with a
// destructor) is a `C&&` in the header a C++ file includes
// (inputs/value_param: vp.k, main.cpp, lvalue.cpp), and a C++ caller has
// C++'s own semantics for it: it passes an rvalue, the callee may take the
// value or leave it, and the caller's object is destroyed where C++
// destroys it, moved-from or not. `count()` returns the destructor calls
// since the last one.
//  - keep reads its parameter: the object stays the caller's, one call.
//  - take moves it out: the result and the caller's moved-from object.
//  - maybe moves it on one path and destroys the value on the other; the
//    caller's object is moved-from either way and destroyed after.
//  - pass<T> names its own type parameter, so it stays by value and C++
//    deduces or names T as before.
//  - a `fn(C) -> i32` parameter takes a C++ function of `C&&`.
// An lvalue does not bind: the class has no copy to make of it.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/inputs/value_param/main.cpp -o %t.d/app 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// RUN: { %kcc -c %S/inputs/value_param/lvalue.cpp -o %t.d/l.o 2>&1 || true; } | %FileCheck %s --check-prefix=LVALUE
// RUN: not %kcc -c %S/inputs/value_param/lvalue.cpp -o %t.d/l.o 2> /dev/null
// QUIET-NOT: {{error|warning}}
// CHECK:      keep 1 live 1
// CHECK-NEXT: keep moved lvalue: 1
// CHECK-NEXT: keep 2
// CHECK-NEXT: keep prvalue: 1
// CHECK-NEXT: take 3 left 0
// CHECK-NEXT: take: 2
// CHECK-NEXT: maybe false left 0
// CHECK-NEXT: maybe false: 2
// CHECK-NEXT: maybe true: 2
// CHECK-NEXT: pass 6 7
// CHECK-NEXT: pass: 2
// CHECK-NEXT: holder 8 left 0
// CHECK-NEXT: holder: 2
// CHECK-NEXT: apply 9
// CHECK-NEXT: apply: 2
// CHECK-EMPTY:
// LVALUE: lvalue.cpp:4:21: error [CL001E]: rvalue reference to type '::vp::C' cannot bind to lvalue of type 'vp::C'
// LVALUE-NEXT: vp.k:15:8: note [I900N]: passing argument to parameter 'c' here
