// The suffix spellings outside `iN` / `uN` / `fN`: upper case (`42U8`,
// `2.5F32`), `bf16` (which has no C++ literal suffix and is spelled through
// an f32 literal), and `usize` / `isize`. Each used to fall through to a
// default the lexer guessed: `1.5bf16` was an f64 and `1usize` an i8.

import std::io::println

fn kind(x: bf16) -> i32 { return 16 }
fn kind(x: f64) -> i32 { return 64 }
fn kind(x: u8) -> i32 { return 8 }
fn kind(x: i16) -> i32 { return 160 }
fn kind(x: f32) -> i32 { return 32 }
fn kind(x: usize) -> i32 { return 1 }
fn kind(x: i32) -> i32 { return 2 }

fn main() -> i32 {
    println(f"{1.5bf16} {42U8} {7I16} {2.5F32} {3usize} {-3isize}")
    println(f"{kind(1.5bf16)} {kind(42U8)} {kind(7I16)} {kind(2.5F32)} {kind(3usize)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ::suffix_spellings::kind(static_cast<__bf16>(1.5f))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      1.5 42 7 2.5 3 -3
// OUT-NEXT: 16 8 160 32 1
