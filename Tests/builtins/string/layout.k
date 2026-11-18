// The layout of string and its companions, in words: a string is two
// words aligned as one, relocatable by copying its bytes; Chars is three
// words; a ParseError is eight bytes, so a panicking parse returns in
// registers. The sizes are compile-time constants.

import std::io

eval W: usize = sizeof usize

eval STRING_SIZE:  bool = sizeof string == 2 * W
eval STRING_ALIGN: bool = alignof string == alignof usize
eval STRING_RELOC: bool = __builtin_is_trivially_relocatable<string>()
eval CHARS_SIZE:   bool = sizeof Chars == 3 * W
eval ERROR_SIZE:   bool = sizeof ParseError == 8

fn main() -> i32 {
    var bad = 0
    eval if !STRING_SIZE { bad += 1 }
    eval if !STRING_ALIGN { bad += 2 }
    eval if !STRING_RELOC { bad += 4 }
    eval if !CHARS_SIZE { bad += 8 }
    eval if !ERROR_SIZE { bad += 16 }

    // A string is destroyed, so it is not trivially destructible, and a
    // moved string leaves its source without a block to free.
    if __builtin_is_trivially_destructible<string>() {
        bad += 64
    }

    var a = "moved".to_owned()
    var b = a
    if !b.is_owned() || b != "moved" {
        bad += 128
    }

    if bad == 0 {
        io::println("ok")
    }

    return bad
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK: ok
