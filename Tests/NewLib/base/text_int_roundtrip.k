// Integer <-> text: every i8/u8/i16/u16, the boundary values of the 32, 64
// and 128-bit types, and seeded random values of every bit length, each
// checked against a digit-at-a-time reference and read back.

import std::io::*
import self::Inputs::numtext_support::*

var max_len_u64:  usize = 0
var max_len_i64:  usize = 0

/// The reference: one digit per division, written forward.
fn ref_u128(v: u128, out: unsafe *u8) -> usize {
    var tmp: [u8; 48]
    var n: usize = 0
    var x = v
    loop {
        tmp[n] = (48 + ((x % 10) as u32)) as u8
        n += 1
        x = x / 10
        if x == 0 {
            break
        }
    }

    for var i: usize = 0; i < n; ++i {
        out[i] = tmp[n - 1 - i]
    }

    return n
}

fn ref_i128(v: i128, out: unsafe *u8) -> usize {
    if v >= 0 {
        return ref_u128(v as u128, out)
    }

    out[0] = 45
    var unsafe *rest = unsafe &out[1]
    return 1 + ref_u128(0u128 - (v as u128), rest)
}

fn same(a: unsafe *const u8, an: usize, b: unsafe *const u8, bn: usize) -> bool {
    if an != bn {
        return false
    }

    for var i: usize = 0; i < an; ++i {
        if a[i] != b[i] {
            return false
        }
    }

    return true
}

/// One signed value through every type it fits.
fn check_signed(no: i32, v: i128) {
    var buf: [u8; 48]
    var want: [u8; 48]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]
    var wn  = ref_i128(v, w)
    var err = ParseError { at: 7, kind: ParseErrorKind::Trailing }

    var r = TextRange { start: 0, len: 0 }
    var unsafe *t = unsafe &buf[0]

    if v >= -9223372036854775808 && v <= 9223372036854775807 {
        var x = v as i64
        r = i64_to_text(x, b, 20)
        if r.len > max_len_i64 { max_len_i64 = r.len }
        t = unsafe &buf[r.start]
        if r.start + r.len != 20 || !same(t, r.len, w, wn) {
            fail(no, f"i64_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_i64(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_i64('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
        eval if sizeof usize == 8 {
            r = isize_to_text(x as isize, b, 20)
            t = unsafe &buf[r.start]
            if !same(t, r.len, w, wn) || parse_isize(w, wn, &err) != (x as isize) || err.kind != ParseErrorKind::None {
                fail(no, f"isize '{show(w, wn)}'")
            }
        }
    } else {
        parse_i64(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_i64('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v >= -2147483648 && v <= 2147483647 {
        var x = v as i32
        r = i32_to_text(x, b, 11)
        t = unsafe &buf[r.start]
        if r.start + r.len != 11 || !same(t, r.len, w, wn) {
            fail(no, f"i32_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_i32(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_i32('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
        eval if sizeof usize == 4 {
            r = isize_to_text(x as isize, b, 20)
            t = unsafe &buf[r.start]
            if !same(t, r.len, w, wn) || parse_isize(w, wn, &err) != (x as isize) || err.kind != ParseErrorKind::None {
                fail(no, f"isize '{show(w, wn)}'")
            }
        }
    } else {
        parse_i32(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_i32('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v >= -32768 && v <= 32767 {
        var x = v as i16
        r = i16_to_text(x, b, 6)
        t = unsafe &buf[r.start]
        if r.start + r.len != 6 || !same(t, r.len, w, wn) {
            fail(no, f"i16_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_i16(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_i16('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
    } else {
        parse_i16(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_i16('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v >= -128 && v <= 127 {
        var x = v as i8
        r = i8_to_text(x, b, 4)
        t = unsafe &buf[r.start]
        if r.start + r.len != 4 || !same(t, r.len, w, wn) {
            fail(no, f"i8_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_i8(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_i8('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
    } else {
        parse_i8(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_i8('{show(w, wn)}') accepted an out-of-range value")
        }
    }
}

/// One unsigned value through every type it fits.
fn check_unsigned(no: i32, v: u128) {
    var buf: [u8; 48]
    var want: [u8; 48]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]
    var wn  = ref_u128(v, w)
    var err = ParseError { at: 7, kind: ParseErrorKind::Trailing }

    var r = TextRange { start: 0, len: 0 }
    var unsafe *t = unsafe &buf[0]

    if v <= 0xFFFFFFFFFFFFFFFF {
        var x = v as u64
        r = u64_to_text(x, b, 20)
        if r.len > max_len_u64 { max_len_u64 = r.len }
        t = unsafe &buf[r.start]
        if r.start + r.len != 20 || !same(t, r.len, w, wn) {
            fail(no, f"u64_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_u64(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_u64('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
        eval if sizeof usize == 8 {
            r = usize_to_text(x as usize, b, 20)
            t = unsafe &buf[r.start]
            if !same(t, r.len, w, wn) || parse_usize(w, wn, &err) != (x as usize) || err.kind != ParseErrorKind::None {
                fail(no, f"usize '{show(w, wn)}'")
            }
        }
    } else {
        parse_u64(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_u64('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v <= 0xFFFFFFFF {
        var x = v as u32
        r = u32_to_text(x, b, 10)
        t = unsafe &buf[r.start]
        if r.start + r.len != 10 || !same(t, r.len, w, wn) {
            fail(no, f"u32_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_u32(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_u32('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
        eval if sizeof usize == 4 {
            r = usize_to_text(x as usize, b, 20)
            t = unsafe &buf[r.start]
            if !same(t, r.len, w, wn) || parse_usize(w, wn, &err) != (x as usize) || err.kind != ParseErrorKind::None {
                fail(no, f"usize '{show(w, wn)}'")
            }
        }
    } else {
        parse_u32(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_u32('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v <= 0xFFFF {
        var x = v as u16
        r = u16_to_text(x, b, 5)
        t = unsafe &buf[r.start]
        if r.start + r.len != 5 || !same(t, r.len, w, wn) {
            fail(no, f"u16_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_u16(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_u16('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
    } else {
        parse_u16(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_u16('{show(w, wn)}') accepted an out-of-range value")
        }
    }

    if v <= 0xFF {
        var x = v as u8
        r = u8_to_text(x, b, 3)
        t = unsafe &buf[r.start]
        if r.start + r.len != 3 || !same(t, r.len, w, wn) {
            fail(no, f"u8_to_text gave '{show(t, r.len)}', want '{show(w, wn)}'")
        }
        if parse_u8(w, wn, &err) != x || err.kind != ParseErrorKind::None {
            fail(no, f"parse_u8('{show(w, wn)}') kind {err.kind as u8} at {err.at}")
        }
    } else {
        parse_u8(w, wn, &err)
        if err.kind != ParseErrorKind::Overflow {
            fail(no, f"parse_u8('{show(w, wn)}') accepted an out-of-range value")
        }
    }
}

fn main() -> i32 {
    // Case 1: every 16-bit value, which covers every i8/u8/i16/u16.
    for var i: i32 = -32768; i <= 65535; ++i {
        if i >= 0 {
            check_unsigned(1, i as u128)
        }

        if i <= 32767 {
            check_signed(1, i as i128)
        }
    }

    // Case 2: around every power of ten and every power of two, both signs.
    var p10: u128 = 1
    for var k: i32 = 0; k < 39; ++k {
        check_unsigned(2, p10 - 1)
        check_unsigned(2, p10)
        check_unsigned(2, p10 + 1)
        if k < 38 {
            check_signed(2, p10 as i128)
            check_signed(2, 0 - (p10 as i128))
            check_signed(2, (p10 as i128) - 1)
            check_signed(2, 1 - (p10 as i128))
            p10 = p10 * 10
        }
    }

    var p2: u128 = 1
    for var k: i32 = 0; k < 128; ++k {
        check_unsigned(2, p2 - 1)
        check_unsigned(2, p2)
        check_unsigned(2, p2 + 1)
        if k < 127 {
            check_signed(2, p2 as i128)
            check_signed(2, (p2 as i128) - 1)
            check_signed(2, 0 - (p2 as i128))
            check_signed(2, 0 - (p2 as i128) - 1)
            check_signed(2, 1 - (p2 as i128))
        }

        p2 = p2 << 1
    }

    // Case 3: the limits themselves.
    check_unsigned(3, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFu128)
    var i128_max: i128 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    check_signed(3, i128_max)
    check_signed(3, 0 - i128_max - 1)
    check_signed(3, 0 - i128_max)

    // Case 4: random values of every bit length.
    var rng = Rng { s: 0x9E3779B97F4A7C15 }
    for var i: i32 = 0; i < 400000; ++i {
        var hi   = rng_next(&rng)
        var lo   = rng_next(&rng)
        var bits = (rng_below(&rng, 128) + 1) as u32
        var v    = ((hi as u128) << 64) | (lo as u128)
        if bits < 128 {
            v = v >> (128 - bits)
        }

        check_unsigned(4, v)
        check_signed(4, v as i128)
    }

    // Case 5: the stated maximum lengths are reached and never exceeded.
    if max_len_u64 != U64_TEXT_MAX || max_len_i64 != I64_TEXT_MAX {
        fail(5, f"longest texts {max_len_u64} {max_len_i64}")
    }

    if first_failure == 0 {
        println("ok")
    }

    return first_failure
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
// The 32-bit arithmetic path, forced on this host.
// RUN: %kairo_new %s -O2 -DKAIRO_NUMTEXT_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
