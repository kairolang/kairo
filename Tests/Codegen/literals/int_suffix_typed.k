// A suffix is a declaration (primitives.mdx, Integers): `1u8` is a u8
// wherever it stands, so the C++ must carry that type too. A bare `1` in
// C++ is an int, and C++ re-resolves what it is handed: every call below
// used to reach `pick(signed int)`, and a deduced template argument or a
// pack element became `int` the same way.

import std::io::println

fn pick(x: u8) -> i32 { return 1 }
fn pick(x: i32) -> i32 { return 2 }
fn pick(x: i64) -> i32 { return 3 }
fn pick(x: u64) -> i32 { return 4 }
fn pick(x: i16) -> i32 { return 5 }
fn pick(x: u16) -> i32 { return 6 }
fn pick(x: i8) -> i32 { return 7 }
fn pick(x: u32) -> i32 { return 8 }
fn pick(x: u128) -> i32 { return 11 }
fn pick(x: i128) -> i32 { return 12 }

// usize and isize are their own overload set: on LP64 they share C++'s
// `unsigned long` / `long` with u64 / i64 (R052E).
fn size_pick(x: usize) -> i32 { return 9 }
fn size_pick(x: isize) -> i32 { return 10 }
fn size_pick(x: u32) -> i32 { return 8 }
fn size_pick(x: i32) -> i32 { return 2 }

fn <T> echo(x: T) -> T { return x }

fn <T> twice(x: T) -> T { return echo(echo(x)) }

fn main() -> i32 {
    println(f"{pick(1u8)} {pick(1i32)} {pick(1i64)} {pick(1u64)} {pick(1i16)} {pick(1u16)}")
    println(f"{pick(1i8)} {pick(1u32)} {size_pick(1usize)} {size_pick(1isize)} {pick(1u128)} {pick(1i128)}")
    // Through a deduced generic: T is the suffix's type, in Kairo and in C++.
    println(f"{pick(echo(7u8))} {size_pick(twice(7u32))} {size_pick(twice(-7isize))}")
    // Through `var`'s inferred type: C++ declares the Kairo type, and the
    // value is the literal's.
    var a = 200u8
    var b = -9i64
    println(f"{pick(a)} {pick(b)} {a} {b}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::int_suffix_typed::pick((static_cast<unsigned char>(1)))
// CXX: ::int_suffix_typed::pick((static_cast<signed int>(1)))
// CXX: ::int_suffix_typed::size_pick((static_cast<decltype(sizeof(0))>(1)))
// CXX: unsigned char a =(static_cast<unsigned char>(200));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      1 2 3 4 5 6
// OUT-NEXT: 7 8 9 10 11 12
// OUT-NEXT: 1 8 10
// OUT-NEXT: 1 3 200 -9
