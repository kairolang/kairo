// HashMap and HashSet are two words and word-aligned; the entry of a map of
// plain values moves as bytes.

import std::io

fn main() -> i32 {
    const w = sizeof usize
    io::println(f"map {sizeof {u64: u64} / w} words, align {alignof {u64: u64} / w}")
    io::println(f"map<string, string> {sizeof {string: string} / w} words")
    io::println(f"set {sizeof {u64} / w} words, align {alignof {string} / w}")
    io::println(f"entry relocatable {__builtin_is_trivially_relocatable<MapEntry<u64, u64>>()}")
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      map 2 words, align 1
// CHECK-NEXT: map<string, string> 2 words
// CHECK-NEXT: set 2 words, align 1
// CHECK-NEXT: entry relocatable true
