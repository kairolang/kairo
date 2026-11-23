// A C++ function template taking an array by reference, `T (&)[N]` or
// `const T (&)[N]`, deduces N (and T) from a Kairo fixed array, as C++
// deduces them from a `T[N]` lvalue: a local, a field, a field through a
// pointer, an array of C++ records. A non-const reference is an `@inout`
// parameter and takes `&a`; a const one, template or not, takes the array
// as it is, const or not, like any `const T&`.

ffi "c++" import "cxx_array_ref_template.h"

import std::io

struct S {
    var buf: [u8; 16]
}

struct C {
    var rbuf: [u8; 32]
    var evs:  [Ev; 4]
}

fn main() -> i32 {
    var   a:  [u8; 16]
    var   s:  S
    var   c:  C
    var   *pc          = &c
    var   w:  [i32; 5]
    const k:  [u8; 4]  = [1, 2, 3, 4]
    io::println(f"{tf(&a, 2)} {tg(&a, 1)} {tc(a)} {nc(a)}")
    io::println(f"{tf(&s.buf, 0)} {tf(&c.rbuf, 1)} {tf(&pc->rbuf, 2)}")
    io::println(f"{tt(&w)} {ttc(w)} {te(&c.evs)} {te(&pc->evs)}")
    io::println(f"{a[0]} {a[1]} {s.buf[0]} {c.rbuf[0]} {c.evs[3].fd}")
    io::println(f"{tc(k)} {ttc(k)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: 14 17 23 23
// CHECK-NEXT: 16 31 30
// CHECK-NEXT: 20 5 4 4
// CHECK-NEXT: 7 9 7 7 3
// CHECK-NEXT: 5 4
