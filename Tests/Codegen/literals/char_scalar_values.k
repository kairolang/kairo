// A `char` literal is a Unicode scalar value and lowers to `char32_t`, so
// every scalar value is a valid literal: a character past U+007F written
// directly or as an escape, and an astral one (U+10000 and above). `\xHH`
// is the code point U+00HH. Each literal's value is checked against its
// code point.
fn main() -> i32 {
    var a = '漢'
    var b = '😀'
    var c = 'é'
    var d = '\U0001F600'
    var e = '\xE9'
    var f = '\xFF'
    var g = 'a'
    var h = '\''
    var j = '\U0010FFFF'
    var k = '\{'
    var l = '\u00e9'
    if (a as u32) != 0x6F22 { return 1 }
    if (b as u32) != 0x1F600 { return 2 }
    if (c as u32) != 0xE9 { return 3 }
    if (d as u32) != 0x1F600 { return 4 }
    if (e as u32) != 0xE9 { return 5 }
    if (f as u32) != 0xFF { return 6 }
    if (g as u32) != 0x61 { return 7 }
    if (h as u32) != 0x27 { return 8 }
    if (j as u32) != 0x10FFFF { return 9 }
    if (k as u32) != 0x7B { return 10 }
    if (l as u32) != 0xE9 { return 11 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
