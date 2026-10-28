// `p as usize` for every pointer shape that reaches it (casting.mdx,
// Pointer to integer): a safe pointer, a `*const`, a pointer to a record and
// to one of its fields, a raw pointer, and an address taken in place. Each is
// a reinterpret_cast in C++: static_cast from a pointer to an integer is
// ill-formed, and was what every one of these used to emit.
//
// The values are checked against each other, never against a constant: an
// address differs from run to run, the distance between two fields does not.

import std::io::println

struct Pair { var a: i32  var b: i32 }

fn main() -> i32 {
    var r = 0
    var x: i32 = 5
    var *p = &x
    const *c = &x
    var s = Pair{a: 1, b: 2}
    var *ps = &s
    var raw: unsafe *i32 = &null
    unsafe { raw = unsafe &x }

    var pa = p as usize
    if pa != 0 { r += 1 }
    if (c as usize) == pa { r += 2 }                    // *const i32: the same address
    if (&x as usize) == pa { r += 4 }                   // in place, no binding
    if (raw as usize) == pa { r += 8 }                  // unsafe *i32
    if ((&s.b as usize) - (ps as usize)) == 4 { r += 16 }   // b sits 4 bytes in
    if (ps as usize) == (&s.a as usize) { r += 32 }     // a pointer to the record is its first field's

    // The two-step narrowing the spec spells for "the low bits of an
    // address": the address, then an ordinary integer narrowing.
    var low = p as usize as u8
    if low == (pa as u8) { r += 64 }
    println(f"r {r}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: decltype(sizeof(0)) pa = reinterpret_cast<decltype(sizeof(0))>(p);
// CXX-NOT: static_cast<decltype(sizeof(0))>(p)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 127
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: r 127
