// Unsuffixed integer literals whose source bytes are not C++ (primitives.mdx:
// "underscores are ignored, use freely as separators", `0o77` octal). They
// were borrowed verbatim: clang read `1_000_000` as 1 with a user-defined
// literal suffix `_000_000`, and has no `0o` prefix at all. They are spelled
// from their value now, and keep taking the type they are used at. Plain
// decimal, hex and binary bytes are still borrowed as written.

import std::io::println

fn main() -> i32 {
    var a = 1_000_000
    var b: u8 = 0b1111_1111
    var c = 0o77
    var d: u16 = 0O1_7
    var e: i64 = -9223372036854775808          // top bit: no signed C++ literal holds it
    var f: u64 = 18446744073709551615
    var g: i128 = -170141183460469231731687303715884105728
    var h = 0xFF
    println(f"{a} {b} {c} {d} {e} {f} {h}")
    println(f"{g}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: signed int a = 1000000;
// CXX-NEXT: unsigned char b = 255;
// CXX-NEXT: signed int c = 63;
// CXX: signed int h = 0xFF;

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      1000000 255 63 15 -9223372036854775808 18446744073709551615 255
// OUT-NEXT: -170141183460469231731687303715884105728
