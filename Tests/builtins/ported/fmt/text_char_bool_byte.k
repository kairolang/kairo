// char, bool and byte holes with width, fill (single- and multi-byte) and alignment; a char built from a code point.
// Rules asserted (website library/core/formatting.mdx, FmtBuf.put_str / put_bool / put_char / put_byte): a string hole is
// padded by width, fill and alignment, default left; the precision truncates to that many code points; width counts code
// points (Compiler/Spec/FormatStrings.md, Capacity bound: "Width pads in codepoints"), never bytes or display columns.
// `?` quotes and escapes (put_str; put_char); a `byte` prints as two lowercase hex digits and `#` adds `0x`.
// Expected texts come from a Python oracle on Python strings (code points).
// Not asserted because the docs do not state them: the spelling of control characters under `?`, a precision together
// with `?`, and the split of an odd amount of padding by `^`.
// Cases from Rust library/coretests/tests/fmt/mod.rs (test_format_macro_interface: string width, precision, fill, alignment)
// Cases from Rust library/alloctests/tests/fmt.rs (padding and precision of strings and chars)
// Cases from the {fmt} library test/format-test.cc (string, char and bool width / fill / alignment cases)

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn chars() {
    var c0: char = 'a'
    var c1: char = 'é'
    var c2: char = '☃'
    var c3: char = '😀'
    var c4: char = '日'
    ck(f"{c0}", "a", 1, "char a {}")
    ck(f"{c0:1}", "a", 1, "char a {1}")
    ck(f"{c0:4}", "a   ", 1, "char a {4}")
    ck(f"{c0:<4}", "a   ", 1, "char a {<4}")
    ck(f"{c0:>4}", "   a", 1, "char a {>4}")
    ck(f"{c0:^5}", "  a  ", 1, "char a {^5}")
    ck(f"{c0:*>5}", "****a", 1, "char a {*>5}")
    ck(f"{c0:→<4}", "a→→→", 1, "char a {→<4}")
    ck(f"{c0:😀^5}", "😀😀a😀😀", 1, "char a {😀^5}")
    ck(f"{c0:0>3}", "00a", 1, "char a {0>3}")
    ck(f"{c1}", "é", 1, "char é {}")
    ck(f"{c1:1}", "é", 1, "char é {1}")
    ck(f"{c1:4}", "é   ", 1, "char é {4}")
    ck(f"{c1:<4}", "é   ", 1, "char é {<4}")
    ck(f"{c1:>4}", "   é", 1, "char é {>4}")
    ck(f"{c1:^5}", "  é  ", 1, "char é {^5}")
    ck(f"{c1:*>5}", "****é", 1, "char é {*>5}")
    ck(f"{c1:→<4}", "é→→→", 1, "char é {→<4}")
    ck(f"{c1:😀^5}", "😀😀é😀😀", 1, "char é {😀^5}")
    ck(f"{c1:0>3}", "00é", 1, "char é {0>3}")
    ck(f"{c2}", "☃", 1, "char ☃ {}")
    ck(f"{c2:1}", "☃", 1, "char ☃ {1}")
    ck(f"{c2:4}", "☃   ", 1, "char ☃ {4}")
    ck(f"{c2:<4}", "☃   ", 1, "char ☃ {<4}")
    ck(f"{c2:>4}", "   ☃", 1, "char ☃ {>4}")
    ck(f"{c2:^5}", "  ☃  ", 1, "char ☃ {^5}")
    ck(f"{c2:*>5}", "****☃", 1, "char ☃ {*>5}")
    ck(f"{c2:→<4}", "☃→→→", 1, "char ☃ {→<4}")
    ck(f"{c2:😀^5}", "😀😀☃😀😀", 1, "char ☃ {😀^5}")
    ck(f"{c2:0>3}", "00☃", 1, "char ☃ {0>3}")
    ck(f"{c3}", "😀", 1, "char 😀 {}")
    ck(f"{c3:1}", "😀", 1, "char 😀 {1}")
    ck(f"{c3:4}", "😀   ", 1, "char 😀 {4}")
    ck(f"{c3:<4}", "😀   ", 1, "char 😀 {<4}")
    ck(f"{c3:>4}", "   😀", 1, "char 😀 {>4}")
    ck(f"{c3:^5}", "  😀  ", 1, "char 😀 {^5}")
    ck(f"{c3:*>5}", "****😀", 1, "char 😀 {*>5}")
    ck(f"{c3:→<4}", "😀→→→", 1, "char 😀 {→<4}")
    ck(f"{c3:😀^5}", "😀😀😀😀😀", 1, "char 😀 {😀^5}")
    ck(f"{c3:0>3}", "00😀", 1, "char 😀 {0>3}")
    ck(f"{c4}", "日", 1, "char 日 {}")
    ck(f"{c4:1}", "日", 1, "char 日 {1}")
    ck(f"{c4:4}", "日   ", 1, "char 日 {4}")
    ck(f"{c4:<4}", "日   ", 1, "char 日 {<4}")
    ck(f"{c4:>4}", "   日", 1, "char 日 {>4}")
    ck(f"{c4:^5}", "  日  ", 1, "char 日 {^5}")
    ck(f"{c4:*>5}", "****日", 1, "char 日 {*>5}")
    ck(f"{c4:→<4}", "日→→→", 1, "char 日 {→<4}")
    ck(f"{c4:😀^5}", "😀😀日😀😀", 1, "char 日 {😀^5}")
    ck(f"{c4:0>3}", "00日", 1, "char 日 {0>3}")
    ck(f"{(65 as char)}", "A", 1, "char U+0041")
    ck(f"{(233 as char)}", "é", 1, "char U+00E9")
    ck(f"{(9786 as char)}", "☺", 1, "char U+263A")
    ck(f"{(128512 as char)}", "😀", 1, "char U+1F600")
}

fn bools() {
    var t = true
    var f = false
    ck(f"{t}", "true", 2, "bool true {}")
    ck(f"{t:3}", "true", 2, "bool true {3}")
    ck(f"{t:5}", "true ", 2, "bool true {5}")
    ck(f"{t:8}", "true    ", 2, "bool true {8}")
    ck(f"{t:<8}", "true    ", 2, "bool true {<8}")
    ck(f"{t:>8}", "    true", 2, "bool true {>8}")
    ck(f"{t:^8}", "  true  ", 2, "bool true {^8}")
    ck(f"{t:*>8}", "****true", 2, "bool true {*>8}")
    ck(f"{t:→<7}", "true→→→", 2, "bool true {→<7}")
    ck(f"{t:😀^6}", "😀true😀", 2, "bool true {😀^6}")
    ck(f"{f}", "false", 2, "bool false {}")
    ck(f"{f:3}", "false", 2, "bool false {3}")
    ck(f"{f:5}", "false", 2, "bool false {5}")
    ck(f"{f:8}", "false   ", 2, "bool false {8}")
    ck(f"{f:<8}", "false   ", 2, "bool false {<8}")
    ck(f"{f:>8}", "   false", 2, "bool false {>8}")
    ck(f"{f:^9}", "  false  ", 2, "bool false {^9}")
    ck(f"{f:*>8}", "***false", 2, "bool false {*>8}")
    ck(f"{f:→<7}", "false→→", 2, "bool false {→<7}")
    ck(f"{1 < 2}", "true", 2, "bool expression")
    ck(f"{!(1 < 2):>7}", "  false", 2, "bool expression padded")
}

fn bytes() {
    var b0: byte = 0
    var b1: byte = 1
    var b2: byte = 15
    var b3: byte = 16
    var b4: byte = 127
    var b5: byte = 128
    var b6: byte = 165
    var b7: byte = 255
    ck(f"{b0}", "00", 3, "byte 0")
    ck(f"{b0:#}", "0x00", 3, "byte 0 {#}")
    ck(f"{b0:>6}", "    00", 3, "byte 0 {>6}")
    ck(f"{b0:*<6}", "00****", 3, "byte 0 {*<6}")
    ck(f"{b1}", "01", 3, "byte 1")
    ck(f"{b1:#}", "0x01", 3, "byte 1 {#}")
    ck(f"{b1:>6}", "    01", 3, "byte 1 {>6}")
    ck(f"{b1:*<6}", "01****", 3, "byte 1 {*<6}")
    ck(f"{b2}", "0f", 3, "byte 15")
    ck(f"{b2:#}", "0x0f", 3, "byte 15 {#}")
    ck(f"{b2:>6}", "    0f", 3, "byte 15 {>6}")
    ck(f"{b2:*<6}", "0f****", 3, "byte 15 {*<6}")
    ck(f"{b3}", "10", 3, "byte 16")
    ck(f"{b3:#}", "0x10", 3, "byte 16 {#}")
    ck(f"{b3:>6}", "    10", 3, "byte 16 {>6}")
    ck(f"{b3:*<6}", "10****", 3, "byte 16 {*<6}")
    ck(f"{b4}", "7f", 3, "byte 127")
    ck(f"{b4:#}", "0x7f", 3, "byte 127 {#}")
    ck(f"{b4:>6}", "    7f", 3, "byte 127 {>6}")
    ck(f"{b4:*<6}", "7f****", 3, "byte 127 {*<6}")
    ck(f"{b5}", "80", 3, "byte 128")
    ck(f"{b5:#}", "0x80", 3, "byte 128 {#}")
    ck(f"{b5:>6}", "    80", 3, "byte 128 {>6}")
    ck(f"{b5:*<6}", "80****", 3, "byte 128 {*<6}")
    ck(f"{b6}", "a5", 3, "byte 165")
    ck(f"{b6:#}", "0xa5", 3, "byte 165 {#}")
    ck(f"{b6:>6}", "    a5", 3, "byte 165 {>6}")
    ck(f"{b6:*<6}", "a5****", 3, "byte 165 {*<6}")
    ck(f"{b7}", "ff", 3, "byte 255")
    ck(f"{b7:#}", "0xff", 3, "byte 255 {#}")
    ck(f"{b7:>6}", "    ff", 3, "byte 255 {>6}")
    ck(f"{b7:*<6}", "ff****", 3, "byte 255 {*<6}")
}

fn main() -> i32 {
    chars()
    bools()
    bytes()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
