// Integer to text for i8, i16, i32, i64, isize, u8, u16, u32, u64 and usize (the last four are 64
// bits wide): every value of the 8 and 16 bit types, the boundaries and the neighbours of every power
// of ten and of two, and a seeded random sample of the wide types, each printed by `as string`, by
// `append_to` and by an f-string hole, and compared with a decimal text built here one digit at a
// time; then each text read back must give the value. Also the f-string formats of an integer:
// base, prefix, sign, width, fill, alignment and zero padding. (The upper-case prefix of `#X` and the
// hexadecimal text of a negative value are not stated by the documentation and are not asserted.)
//
// The rule: the shortest decimal text, `-` before a negative value, no `+`, no leading zeros;
// the minimum of a signed type prints in full.
// Cases from Rust library/coretests/tests/num/{i8,i16,i32,i64,u8,u16,u32,u64}.rs and
// library/coretests/tests/num/mod.rs (minimum and maximum, round trips through text)

import std::io

static CODE: i32 = 0
static NO:   i32 = 0

fn fail(const what: string) {
    io::println(f"FAIL case {NO}: {what}")
    if CODE == 0 {
        CODE = if NO > 250 => 250 else => NO
    }
}

fn digit(d: u64) -> char {
    return (48 + d) as char
}

/// The decimal text of `v`, one digit at a time from the right.
fn ref_u(v: u64) -> string {
    if v == 0 {
        return "0"
    }

    var out = ""
    var x   = v
    while x != 0 {
        out = f"{digit(x % 10)}{out}"
        x   = x / 10
    }

    return out
}

fn ref_i(v: i64) -> string {
    if v >= 0 {
        return ref_u(v as u64)
    }

    // 0 - v wraps to the magnitude, the minimum included.
    return f"-{ref_u(0u64 - (v as u64))}"
}

fn chk(const got: string, const app: string, const fs: string, const want: string, const what: string) {
    NO += 1
    if got != want || app != want || fs != want {
        fail(f"{what} printed '{got}' / '{app}' / '{fs}', want '{want}'")
    }
}

fn do_i8(v: i8) {
    var want = ref_i(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "i8")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = i8::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"i8 '{want}' did not read back")
    }
}

fn do_u8(v: u8) {
    var want = ref_u(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "u8")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = u8::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"u8 '{want}' did not read back")
    }
}

fn do_i16(v: i16) {
    var want = ref_i(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "i16")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = i16::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"i16 '{want}' did not read back")
    }
}

fn do_u16(v: u16) {
    var want = ref_u(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "u16")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = u16::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"u16 '{want}' did not read back")
    }
}

fn do_i32(v: i32) {
    var want = ref_i(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "i32")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = i32::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"i32 '{want}' did not read back")
    }
}

fn do_u32(v: u32) {
    var want = ref_u(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "u32")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = u32::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"u32 '{want}' did not read back")
    }
}

fn do_i64(v: i64) {
    var want = ref_i(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "i64")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = i64::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"i64 '{want}' did not read back")
    }

    var w: isize = v as isize
    var app2 = string()
    w.append_to(&app2)
    chk(w as string, app2, f"{w}", want, "isize")
    var r2? = isize::from_str(want, &err)
    NO += 1
    if !(r2?) || r2 != w {
        fail(f"isize '{want}' did not read back")
    }
}

fn do_u64(v: u64) {
    var want = ref_u(v)
    var app  = string()
    v.append_to(&app)
    chk(v as string, app, f"{v}", want, "u64")
    var err = ParseError { at: 9, kind: ParseErrorKind::Trailing }
    var r?  = u64::from_str(want, &err)
    NO += 1
    if !(r?) || r != v || err.kind != ParseErrorKind::None {
        fail(f"u64 '{want}' did not read back")
    }

    var w: usize = v as usize
    var app2 = string()
    w.append_to(&app2)
    chk(w as string, app2, f"{w}", want, "usize")
    var r2? = usize::from_str(want, &err)
    NO += 1
    if !(r2?) || r2 != w {
        fail(f"usize '{want}' did not read back")
    }
}

fn small_types_exhaustively() {
    for var v: i32 = -128; v < 128; ++v {
        do_i8(v as i8)
    }

    for var v: i32 = 0; v < 256; ++v {
        do_u8(v as u8)
    }

    for var v: i32 = -32768; v < 32768; ++v {
        do_i16(v as i16)
    }

    for var v: i32 = 0; v < 65536; ++v {
        do_u16(v as u16)
    }
}

fn powers_and_boundaries() {
    var p: u64 = 1
    for var k = 0; k < 20; ++k {
        for var d: i32 = -2; d <= 2; ++d {
            var u = p + (d as u64)
            do_u64(u)
            do_i64(u as i64)
            do_u32(u as u32)
            do_i32(u as i32)
            do_i64((0u64 - u) as i64)
        }

        p *= 10
    }

    for var k: u64 = 0; k < 64; ++k {
        var q: u64 = 1u64 << k
        for var d: i32 = -2; d <= 2; ++d {
            var u = q + (d as u64)
            do_u64(u)
            do_i64(u as i64)
            do_u32(u as u32)
            do_i32(u as i32)
            do_u16(u as u16)
            do_i16(u as i16)
            do_u8(u as u8)
            do_i8(u as i8)
            do_i64((0u64 - u) as i64)
        }
    }

    do_i64(-9223372036854775807 - 1)
    do_i64(9223372036854775807)
    do_u64(18446744073709551615)
    do_i32(-2147483647 - 1)
    do_i32(2147483647)
    do_u32(4294967295)
}

fn random_sample() {
    var s: u64 = 0x9E3779B97F4A7C15
    for var i = 0; i < 40000; ++i {
        s = s ^ (s >> 12)
        s = s ^ (s << 25)
        s = s ^ (s >> 27)
        var x = s * 0x2545F4914F6CDD1D
        // A random width, so every digit count shows up.
        var w = (x >> 58) + 1
        var m = x >> (64 - w)
        do_u64(m)
        do_i64(m as i64)
        do_i64((0u64 - m) as i64)
        do_u32(m as u32)
        do_i32(m as i32)
    }
}

fn fs_cases() {
    var n: i32 = 255
    var neg: i32 = -255
    NO += 1
    if f"{n:x}" != "ff" || f"{n:X}" != "FF" || f"{n:o}" != "377" || f"{n:b}" != "11111111" {
        fail(f"bases: {n:x} {n:X} {n:o} {n:b}")
    }

    NO += 1
    if f"{n:#x}" != "0xff" || f"{n:#o}" != "0o377" || f"{n:#b}" != "0b11111111" {
        fail(f"prefixes: {n:#x} {n:#o} {n:#b}")
    }

    NO += 1
    if f"{n:+}" != "+255" || f"{neg:+}" != "-255" || f"{0:+}" != "+0" {
        fail(f"signs: {n:+} {neg:+} {0:+}")
    }

    var five: i32 = 5
    NO += 1
    if f"{five:3}" != "  5" || f"{five:<3}|" != "5  |" || f"{five:>3}" != "  5" || f"{five:^5}" != "  5  " || f"{five:^4}" != " 5  " {
        fail(f"width and alignment: '{five:3}' '{five:<3}' '{five:>3}' '{five:^5}' '{five:^4}'")
    }

    NO += 1
    if f"{five:*^5}" != "**5**" || f"{five:-<4}" != "5---" || f"{five:0>3}" != "005" {
        fail(f"fill: '{five:*^5}' '{five:-<4}' '{five:0>3}'")
    }

    NO += 1
    if f"{five:03}" != "005" || f"{neg:06}" != "-00255" || f"{n:+06}" != "+00255" || f"{n:#06x}" != "0x00ff" || f"{n:#010b}" != "0b11111111" {
        fail(f"zero padding: '{five:03}' '{neg:06}' '{n:+06}' '{n:#06x}' '{n:#010b}'")
    }

    NO += 1
    if f"{five:1}" != "5" || f"{n:2}" != "255" || f"{n:0}" != "255" {
        fail("a width below the text length changes nothing")
    }

    var big: u64 = 18446744073709551615
    var small: i64 = -9223372036854775807 - 1
    NO += 1
    if f"{big:x}" != "ffffffffffffffff" || f"{big:#b}" != "0b1111111111111111111111111111111111111111111111111111111111111111" {
        fail(f"wide bases: {big:x} {big:#b}")
    }

    NO += 1
    if f"{small:25}" != "     -9223372036854775808" || f"{big:<22}|" != "18446744073709551615  |" {
        fail(f"wide widths: '{small:25}' '{big:<22}'")
    }
}

fn main() -> i32 {
    small_types_exhaustively()
    powers_and_boundaries()
    random_sample()
    fs_cases()
    if CODE == 0 {
        io::println(f"ok {NO} cases")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok {{[0-9]+}} cases
