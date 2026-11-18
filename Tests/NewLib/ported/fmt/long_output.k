// Outputs that outgrow the formatter's 127 inline bytes: padding to widths around the boundary and to the 65535
// limit, multi-byte fill characters (up to 1 200 bytes for 300 code points), very wide integers in binary, a float
// at the 65534 precision limit, and holes that cross the boundary in the middle of an f-string.
// Rules asserted (website library/core/formatting.mdx, FmtBuf: up to 127 bytes live inside the object and longer text
// spills to the heap; width pads in code points, Compiler/Spec/FormatStrings.md, Capacity bound; the spec word
// holds a width up to 65535 and a precision up to 65534, spec grammar in Compiler/Sema/Type/LiteralTyping.k).
// Cases from Rust library/coretests/tests/fmt/float.rs (test_format_f64_max_precision_exponential: the 65535-digit output)
// Cases from Rust library/coretests/tests/fmt/num.rs (test_format_int_exp_precision: huge precision)
// Cases from Rust library/alloctests/tests/fmt.rs (long padded outputs)
// Cases from the {fmt} library test/format-test.cc (large width and precision tests)

import std::io::*

var CODE: i32 = 0

fn fail(id: i32, const msg: string) {
    println(f"FAIL {msg}")
    if CODE == 0 {
        CODE = id
    }
}

// The string has `bytes` bytes and `cps` code points, and every byte before `lead` is `c`.
fn shape(const s: string, bytes: usize, cps: usize, id: i32, const name: string) {
    if s.size() != bytes || s.codepoints() != cps {
        fail(id, f"{name}: {s.size()} bytes {s.codepoints()} code points, want {bytes} and {cps}")
    }
}

// Every byte of s[from..to) is c.
fn all_bytes(const s: string, from: usize, to: usize, c: u8) -> bool {
    var b = s.bytes()
    if to > b.size() {
        return false
    }

    for var i = from; i < to; i += 1 {
        if b[i] != c {
            return false
        }
    }

    return true
}

fn pad_boundaries() {
    var e = ""
    var t = "ab"

    {
        var r = f"{e:x>1}"
        shape(r, 1, 1, 1, "right fill 1")
        if !all_bytes(r, 0, 1, 120) { fail(1, "right fill 1 content") }
    }
    {
        var r = f"{e:x>2}"
        shape(r, 2, 2, 1, "right fill 2")
        if !all_bytes(r, 0, 2, 120) { fail(1, "right fill 2 content") }
    }
    {
        var r = f"{e:x>126}"
        shape(r, 126, 126, 1, "right fill 126")
        if !all_bytes(r, 0, 126, 120) { fail(1, "right fill 126 content") }
    }
    {
        var r = f"{e:x>127}"
        shape(r, 127, 127, 1, "right fill 127")
        if !all_bytes(r, 0, 127, 120) { fail(1, "right fill 127 content") }
    }
    {
        var r = f"{t:y<127}"
        shape(r, 127, 127, 1, "left fill 127")
        if !r.starts_with("ab") || !all_bytes(r, 2, 127, 121) { fail(1, "left fill 127 content") }
    }
    {
        var r = f"{t:z^128}"
        shape(r, 128, 128, 1, "centred fill 127")
        if !all_bytes(r, 0, 63, 122) || !all_bytes(r, 65, 128, 122) { fail(1, "centred fill 127 content") }
    }
    {
        var r = f"{e:x>128}"
        shape(r, 128, 128, 1, "right fill 128")
        if !all_bytes(r, 0, 128, 120) { fail(1, "right fill 128 content") }
    }
    {
        var r = f"{t:y<128}"
        shape(r, 128, 128, 1, "left fill 128")
        if !r.starts_with("ab") || !all_bytes(r, 2, 128, 121) { fail(1, "left fill 128 content") }
    }
    {
        var r = f"{t:z^128}"
        shape(r, 128, 128, 1, "centred fill 128")
        if !all_bytes(r, 0, 63, 122) || !all_bytes(r, 65, 128, 122) { fail(1, "centred fill 128 content") }
    }
    {
        var r = f"{e:x>129}"
        shape(r, 129, 129, 1, "right fill 129")
        if !all_bytes(r, 0, 129, 120) { fail(1, "right fill 129 content") }
    }
    {
        var r = f"{e:x>254}"
        shape(r, 254, 254, 1, "right fill 254")
        if !all_bytes(r, 0, 254, 120) { fail(1, "right fill 254 content") }
    }
    {
        var r = f"{e:x>255}"
        shape(r, 255, 255, 1, "right fill 255")
        if !all_bytes(r, 0, 255, 120) { fail(1, "right fill 255 content") }
    }
    {
        var r = f"{t:y<255}"
        shape(r, 255, 255, 1, "left fill 255")
        if !r.starts_with("ab") || !all_bytes(r, 2, 255, 121) { fail(1, "left fill 255 content") }
    }
    {
        var r = f"{t:z^256}"
        shape(r, 256, 256, 1, "centred fill 255")
        if !all_bytes(r, 0, 127, 122) || !all_bytes(r, 129, 256, 122) { fail(1, "centred fill 255 content") }
    }
    {
        var r = f"{e:x>256}"
        shape(r, 256, 256, 1, "right fill 256")
        if !all_bytes(r, 0, 256, 120) { fail(1, "right fill 256 content") }
    }
    {
        var r = f"{t:y<256}"
        shape(r, 256, 256, 1, "left fill 256")
        if !r.starts_with("ab") || !all_bytes(r, 2, 256, 121) { fail(1, "left fill 256 content") }
    }
    {
        var r = f"{t:z^256}"
        shape(r, 256, 256, 1, "centred fill 256")
        if !all_bytes(r, 0, 127, 122) || !all_bytes(r, 129, 256, 122) { fail(1, "centred fill 256 content") }
    }
    {
        var r = f"{e:x>1000}"
        shape(r, 1000, 1000, 1, "right fill 1000")
        if !all_bytes(r, 0, 1000, 120) { fail(1, "right fill 1000 content") }
    }
    {
        var r = f"{t:y<1000}"
        shape(r, 1000, 1000, 1, "left fill 1000")
        if !r.starts_with("ab") || !all_bytes(r, 2, 1000, 121) { fail(1, "left fill 1000 content") }
    }
    {
        var r = f"{t:z^1000}"
        shape(r, 1000, 1000, 1, "centred fill 1000")
        if !all_bytes(r, 0, 499, 122) || !all_bytes(r, 501, 1000, 122) { fail(1, "centred fill 1000 content") }
    }
    {
        var r = f"{e:x>4096}"
        shape(r, 4096, 4096, 1, "right fill 4096")
        if !all_bytes(r, 0, 4096, 120) { fail(1, "right fill 4096 content") }
    }
    {
        var r = f"{e:x>10000}"
        shape(r, 10000, 10000, 1, "right fill 10000")
        if !all_bytes(r, 0, 10000, 120) { fail(1, "right fill 10000 content") }
    }
    {
        var r = f"{e:x>65535}"
        shape(r, 65535, 65535, 1, "right fill 65535")
        if !all_bytes(r, 0, 65535, 120) { fail(1, "right fill 65535 content") }
    }
}

fn multibyte_fill() {
    var e = ""
    var t = "ab"

    {
        var r = f"{e:→>43}"
        shape(r, 129, 43, 2, "→ right 43")
        if !(r == f"{e:→<43}") { fail(2, "→ 43: left and right of nothing differ") }
    }
    {
        var r = f"{e:→>63}"
        shape(r, 189, 63, 2, "→ right 63")
        if !(r == f"{e:→<63}") { fail(2, "→ 63: left and right of nothing differ") }
    }
    {
        var r = f"{e:→>64}"
        shape(r, 192, 64, 2, "→ right 64")
        if !(r == f"{e:→<64}") { fail(2, "→ 64: left and right of nothing differ") }
    }
    {
        var r = f"{e:→>100}"
        shape(r, 300, 100, 2, "→ right 100")
        if !(r == f"{e:→<100}") { fail(2, "→ 100: left and right of nothing differ") }
    }
    {
        var r = f"{e:→>300}"
        shape(r, 900, 300, 2, "→ right 300")
        if !(r == f"{e:→<300}") { fail(2, "→ 300: left and right of nothing differ") }
    }
    {
        var r = f"{t:→^102}"
        shape(r, 302, 102, 2, "→ centred around two ASCII bytes")
        if !r.contains("ab") { fail(2, "→ centred content") }
    }
    {
        var r = f"{e:😀>43}"
        shape(r, 172, 43, 2, "😀 right 43")
        if !(r == f"{e:😀<43}") { fail(2, "😀 43: left and right of nothing differ") }
    }
    {
        var r = f"{e:😀>63}"
        shape(r, 252, 63, 2, "😀 right 63")
        if !(r == f"{e:😀<63}") { fail(2, "😀 63: left and right of nothing differ") }
    }
    {
        var r = f"{e:😀>64}"
        shape(r, 256, 64, 2, "😀 right 64")
        if !(r == f"{e:😀<64}") { fail(2, "😀 64: left and right of nothing differ") }
    }
    {
        var r = f"{e:😀>100}"
        shape(r, 400, 100, 2, "😀 right 100")
        if !(r == f"{e:😀<100}") { fail(2, "😀 100: left and right of nothing differ") }
    }
    {
        var r = f"{e:😀>300}"
        shape(r, 1200, 300, 2, "😀 right 300")
        if !(r == f"{e:😀<300}") { fail(2, "😀 300: left and right of nothing differ") }
    }
    {
        var r = f"{t:😀^102}"
        shape(r, 402, 102, 2, "😀 centred around two ASCII bytes")
        if !r.contains("ab") { fail(2, "😀 centred content") }
    }
    {
        var r = f"{e:日>43}"
        shape(r, 129, 43, 2, "日 right 43")
        if !(r == f"{e:日<43}") { fail(2, "日 43: left and right of nothing differ") }
    }
    {
        var r = f"{e:日>63}"
        shape(r, 189, 63, 2, "日 right 63")
        if !(r == f"{e:日<63}") { fail(2, "日 63: left and right of nothing differ") }
    }
    {
        var r = f"{e:日>64}"
        shape(r, 192, 64, 2, "日 right 64")
        if !(r == f"{e:日<64}") { fail(2, "日 64: left and right of nothing differ") }
    }
    {
        var r = f"{e:日>100}"
        shape(r, 300, 100, 2, "日 right 100")
        if !(r == f"{e:日<100}") { fail(2, "日 100: left and right of nothing differ") }
    }
    {
        var r = f"{e:日>300}"
        shape(r, 900, 300, 2, "日 right 300")
        if !(r == f"{e:日<300}") { fail(2, "日 300: left and right of nothing differ") }
    }
    {
        var r = f"{t:日^102}"
        shape(r, 302, 102, 2, "日 centred around two ASCII bytes")
        if !r.contains("ab") { fail(2, "日 centred content") }
    }
    {
        var r = f"{e:é>43}"
        shape(r, 86, 43, 2, "é right 43")
        if !(r == f"{e:é<43}") { fail(2, "é 43: left and right of nothing differ") }
    }
    {
        var r = f"{e:é>63}"
        shape(r, 126, 63, 2, "é right 63")
        if !(r == f"{e:é<63}") { fail(2, "é 63: left and right of nothing differ") }
    }
    {
        var r = f"{e:é>64}"
        shape(r, 128, 64, 2, "é right 64")
        if !(r == f"{e:é<64}") { fail(2, "é 64: left and right of nothing differ") }
    }
    {
        var r = f"{e:é>100}"
        shape(r, 200, 100, 2, "é right 100")
        if !(r == f"{e:é<100}") { fail(2, "é 100: left and right of nothing differ") }
    }
    {
        var r = f"{e:é>300}"
        shape(r, 600, 300, 2, "é right 300")
        if !(r == f"{e:é<300}") { fail(2, "é 300: left and right of nothing differ") }
    }
    {
        var r = f"{t:é^102}"
        shape(r, 202, 102, 2, "é centred around two ASCII bytes")
        if !r.contains("ab") { fail(2, "é centred content") }
    }
}

fn wide_numbers() {
    var one: u512 = 1
    var all: u512 = ~(0 as u512)
    var top = (one << 511)
    var neg: i512 = 0 - (1 as i512)
    var r = f"{all:#b}"
    shape(r, 514, 514, 3, "u512 max in binary with a prefix")
    if !r.starts_with("0b1") || !all_bytes(r, 2, 514, 49) {
        fail(3, "u512 max in binary content")
    }

    var r2 = f"{top:b}"
    shape(r2, 512, 512, 3, "2^511 in binary")
    if r2.bytes()[0] != 49 || !all_bytes(r2, 1, 512, 48) {
        fail(3, "2^511 in binary content")
    }

    var r3 = f"{one:#0600b}"
    shape(r3, 600, 600, 3, "1 zero padded to 600 after the prefix")
    if !r3.starts_with("0b") || !all_bytes(r3, 2, 599, 48) || r3.bytes()[599] != 49 {
        fail(3, "1 zero padded content")
    }

    var r4 = f"{neg:*>200}"
    shape(r4, 200, 200, 3, "i512 -1 filled to 200")
    if !r4.ends_with("-1") || !all_bytes(r4, 0, 198, 42) {
        fail(3, "i512 -1 filled content")
    }

    var r5 = f"{all:→<300x}"
    shape(r5, 128 + 172 * 3, 300, 3, "u512 max in hex, multi-byte fill to 300")
    if !r5.starts_with("ffffffff") {
        fail(3, "u512 max hex content")
    }

    var r6 = f"{all:>+200}"
    shape(r6, 200, 200, 3, "u512 max in decimal with a sign, width 200")
    if !r6.starts_with("+") && !r6.starts_with(" ") {
        fail(3, "u512 max sign content")
    }
}

fn float_limits() {
    var one = 1.0
    var zero = 0.0
    var r = f"{one:.65534e}"
    shape(r, 2 + 65534 + 4, 2 + 65534 + 4, 4, "1.0 at the largest precision")
    if !r.starts_with("1.") || !r.ends_with("e+00") || !all_bytes(r, 2, 2 + 65534, 48) {
        fail(4, "1.0 at the largest precision content")
    }

    var z = f"{zero:.65534e}"
    shape(z, 2 + 65534 + 4, 2 + 65534 + 4, 4, "0.0 at the largest precision")
    if !z.starts_with("0.") || !z.ends_with("e+00") || !all_bytes(z, 2, 2 + 65534, 48) {
        fail(4, "0.0 at the largest precision content")
    }

    var w = f"{one:65535.65534e}"
    shape(w, 2 + 65534 + 4, 2 + 65534 + 4, 4, "width below the length changes nothing")
    var p = f"{one:*>65535.3e}"
    shape(p, 65535, 65535, 4, "width 65535 on a short float")
    if !p.ends_with("1.000e+00") || !all_bytes(p, 0, 65535 - 9, 42) {
        fail(4, "width 65535 float content")
    }

    var d = f"{one:.400}"
    if d != "1" {
        fail(4, f"a default-layout precision beyond the digits: {d}")
    }

    var d2 = f"{0.1:.60e}"
    shape(d2, 2 + 60 + 4, 2 + 60 + 4, 4, "0.1 with 60 digits")
    if !d2.starts_with("1.000000000000000055511151231257827021181583404541015625") {
        fail(4, f"0.1 with 60 digits: {d2}")
    }
}

fn crossing() {
    var a = "abcdefghij"
    var n = 1234567
    var parts = ""
    parts += f"{a:*>40}"
    parts += f"{n:#x}"
    parts += f"{a:*<40}"
    parts += f"{n:>40}"
    parts += f"{a:>40}"
    var joined = f"{a:*>40}{n:#x}{a:*<40}{n:>40}{a:>40}"
    if !(parts == joined) {
        fail(5, "holes that cross 127 bytes differ from the pieces")
    }

    shape(joined, 40 + 8 + 40 + 40 + 40, 40 + 8 + 40 + 40 + 40, 5, "five holes")
    var many = f"{a}{a}{a}{a}{a}{a}{a}{a}{a}{a}{a}{a}{a}{n}{a}{a}"
    shape(many, 15 * 10 + 7, 15 * 10 + 7, 5, "sixteen holes")
    var lead = f"{"":q>126}{n}{a}"
    shape(lead, 126 + 7 + 10, 126 + 7 + 10, 5, "digits straddle the boundary")
    if !lead.ends_with("1234567abcdefghij") {
        fail(5, "digits straddle the boundary content")
    }

    var accents = f"{"é":é>70}{"☃":☃<70}"
    shape(accents, 70 * 2 + 70 * 3, 140, 5, "two-byte then three-byte fill")
}

fn main() -> i32 {
    pad_boundaries()
    multibyte_fill()
    wide_numbers()
    float_limits()
    crossing()
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
