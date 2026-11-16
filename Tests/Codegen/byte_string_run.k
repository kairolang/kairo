// A byte string at run time: the slice's pointer and length, each escape one
// byte, an embedded NUL and 0xff kept, no terminator counted. The bytes are
// static storage, so the slice may be returned, stored in a global and
// passed on.

import std::io

const MAGIC: [const u8;] = b"\x7fELF"

fn sum(xs: [const u8;]) -> u32 {
    var t: u32 = 0
    for var i: usize = 0; i < xs.len; ++i {
        t += xs[i]
    }

    return t
}

fn tag() -> [const u8;] {
    return b"tag"
}

macro bytes_of!(x) { sum(x) }
macro twice!(b) { b + b }

fn main() -> i32 {
    var s = b"a\x00\xffz"
    io::println(f"{s.len} {s[0]} {s[1]} {s[2]} {s[3]}")

    var e = b""
    io::println(f"{e.len}")

    var esc = b"\n\t\\\"\0\033\377"
    io::println(f"{esc.len} {esc[0]} {esc[1]} {esc[2]} {esc[3]} {esc[4]} {esc[5]} {esc[6]}")

    var joined = b"ab" b"\x01"
        b"cd"
    io::println(f"{joined.len} {sum(joined)}")

    io::println(f"{sum(b"\x01\x02\x03")} {tag().len} {MAGIC.len} {MAGIC[0]} {sum(MAGIC[1..])}")

    var count: u32 = 0
    for c in b"\x05\x06" {
        count += c
    }

    io::println(f"{count} {bytes_of!(b"\x10\x20")}")

    // `b` stays an ordinary name.
    var b = 21
    var text = "x"
    io::println(f"{twice!(b)} {b} {text}")
    return 0
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      4 97 0 255 122
// CHECK-NEXT: 0
// CHECK-NEXT: 7 10 9 92 34 0 27 255
// CHECK-NEXT: 5 395
// CHECK-NEXT: 6 3 4 127 215
// CHECK-NEXT: 11 48
// CHECK-NEXT: 42 21 x
//
// The lowering is the slice constructor over the static bytes, and nothing
// else: no string is built.
// RUN: %kairo %s --print-ir 2>&1 | %FileCheck %s --check-prefix=IR
// IR: Slice<const unsigned char> s = ::builtin::containers::slice::Slice<const unsigned char>(reinterpret_cast<const unsigned char *>("a\000\377z"), 4);
