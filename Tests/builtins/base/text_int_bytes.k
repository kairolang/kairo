// Text to integer, byte by byte: texts of 1 to 10 bytes, with every byte
// value at every position, through every integer type, against a reference
// parser written from the rules alone. Texts of one to eight digits take a
// different path from longer ones and from signed texts, so the lengths
// around eight, a byte just outside '0'..'9' at each place, and values just
// past each type's limit are where the two could disagree.
//
// The rules (as in text_int_errors.k): empty is Empty at 0; a lone sign is
// InvalidChar at 0; a non-digit where the first digit belongs is
// InvalidChar there; bytes after the digits are Trailing at the first of
// them; digits out of range are Overflow at the digit that first takes the
// value past the limit.

import std::io::*
import self::inputs::numtext_support::*

var case_no: i32 = 0

/// The reference: kind, offset and value of `p[0 .. n)` as an integer in
/// `[-(max + 1), max]` (signed) or `[0, max]`.
struct Want {
    var kind: ParseErrorKind
    var at:   u32
    var mag:  u64
    var neg:  bool
}

fn is_digit(b: u8) -> bool {
    return b >= 48 && b <= 57
}

fn reference(p: unsafe *const u8, n: usize, is_signed: bool, max: u64) -> Want {
    if n == 0 {
        return Want { kind: ParseErrorKind::Empty, at: 0, mag: 0, neg: false }
    }

    var i: usize = 0
    var neg      = false
    if p[0] == 43 || (is_signed && p[0] == 45) {
        if n == 1 {
            return Want { kind: ParseErrorKind::InvalidChar, at: 0, mag: 0, neg: false }
        }

        neg = p[0] == 45
        i   = 1
    }

    if !is_digit(p[i]) {
        return Want { kind: ParseErrorKind::InvalidChar, at: i as u32, mag: 0, neg: false }
    }

    var j = i
    while j < n && is_digit(p[j]) {
        j += 1
    }

    if j < n {
        return Want { kind: ParseErrorKind::Trailing, at: j as u32, mag: 0, neg: false }
    }

    var limit: u128 = (max as u128) + (if neg => 1u128 else => 0u128)
    var acc:   u128 = 0
    for var k = i; k < n; ++k {
        acc = acc * 10 + ((p[k] - 48) as u128)
        if acc > limit {
            return Want { kind: ParseErrorKind::Overflow, at: k as u32, mag: 0, neg: false }
        }
    }

    return Want { kind: ParseErrorKind::None, at: 0, mag: acc as u64, neg: neg }
}

fn check(p: unsafe *const u8, n: usize, is_signed: bool, max: u64, const name: string, got_kind: ParseErrorKind, got_at: u32, got: u64) {
    case_no += 1
    var w = reference(p, n, is_signed, max)
    var want: u64 = if w.neg => 0u64 - w.mag else => w.mag
    if got_kind != w.kind || (w.kind != ParseErrorKind::None && got_at != w.at) || (w.kind == ParseErrorKind::None && got != want) {
        fail(case_no, f"{name}('{show(p, n)}') gave kind {got_kind as u8} at {got_at} value {got}, want kind {w.kind as u8} at {w.at} value {want}")
    }
}

/// Every integer type on `p[0 .. n)`. A failed parse's value is not compared.
fn all_types(p: unsafe *const u8, n: usize) {
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    var a   = parse_u8(p, n, &err)
    check(p, n, false, 0xFF, "u8", err.kind, err.at, a)
    var b = parse_u16(p, n, &err)
    check(p, n, false, 0xFFFF, "u16", err.kind, err.at, b)
    var c = parse_u32(p, n, &err)
    check(p, n, false, 0xFFFFFFFF, "u32", err.kind, err.at, c)
    var d = parse_u64(p, n, &err)
    check(p, n, false, 0xFFFFFFFFFFFFFFFF, "u64", err.kind, err.at, d)
    var e = parse_i8(p, n, &err)
    check(p, n, true, 0x7F, "i8", err.kind, err.at, (e as i64) as u64)
    var f = parse_i16(p, n, &err)
    check(p, n, true, 0x7FFF, "i16", err.kind, err.at, (f as i64) as u64)
    var g = parse_i32(p, n, &err)
    check(p, n, true, 0x7FFFFFFF, "i32", err.kind, err.at, (g as i64) as u64)
    var h = parse_i64(p, n, &err)
    check(p, n, true, 0x7FFFFFFFFFFFFFFF, "i64", err.kind, err.at, h as u64)
}

/// `base` with each byte replaced in turn by every byte value.
fn every_byte(const base: string) {
    var buf: [u8; 16]
    var n = base.size()
    for var i: usize = 0; i < n; ++i {
        buf[i] = base.bytes()[i]
    }

    var unsafe *p = unsafe (&buf[0] as unsafe *const u8)
    all_types(p, n)
    for var j: usize = 0; j < n; ++j {
        var keep = buf[j]
        for var v: u32 = 0; v < 256; ++v {
            buf[j] = v as u8
            all_types(p, n)
        }

        buf[j] = keep
    }
}

fn main() -> i32 {
    var bases: [string; 22] = [
        "7", "42", "255", "256", "999", "1000", "-128", "-129", "+77", "65535", "65536",
        "1234567", "-1234567", "12345678", "99999999", "-9999999", "123456789", "-12345678",
        "4294967295", "4294967296", "0000000001", "+0000000",
    ]
    for var i: usize = 0; i < 22; ++i {
        every_byte(bases[i])
    }

    // Random digit texts of every length 1 to 10, signed and not.
    var r = Rng { s: 0x5eed0001u64 }
    var buf: [u8; 16]
    for var round = 0; round < 20000; ++round {
        var n     = 1 + (rng_below(&r, 10) as usize)
        var start = 0usize
        var lead  = rng_below(&r, 4)
        if lead == 0 && n > 1 {
            buf[0] = 45
            start  = 1
        } else if lead == 1 && n > 1 {
            buf[0] = 43
            start  = 1
        }

        for var k = start; k < n; ++k {
            buf[k] = (48 + rng_below(&r, 10)) as u8
        }

        all_types(unsafe (&buf[0] as unsafe *const u8), n)
    }

    if first_failure == 0 {
        println(f"ok {case_no}")
    }

    return first_failure
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
