// Text to f64 and f32 at the edges of the one-operation path, against
// std::from_chars. A significand at most 2^53 (2^24) with a power of ten up
// to 10^22 (10^10) is exact in the type and reads with one multiply or
// divide; one past either edge must not. Each significand near the edges
// is written with its exponent spelled out, with a decimal point inside
// it, and behind leading zeros that take the text past 19 digits (where
// the digits are taken again, since the running value may have wrapped),
// and also with trailing zeros that do the same.

ffi "c++" import "inputs/oracle.h"

import std::io::*
import self::inputs::numtext_support::*

var case_no: i32 = 0

/// Appends `s` at `b[n]`; returns the new length.
fn put_text(b: unsafe *u8, n: usize, const s: string) -> usize {
    var m = s.size()
    for var i: usize = 0; i < m; ++i {
        b[n + i] = s.bytes()[i]
    }

    return n + m
}

fn put_zeros(b: unsafe *u8, n: usize, k: usize) -> usize {
    for var i: usize = 0; i < k; ++i {
        b[n + i] = 48
    }

    return n + k
}

fn check64(b: unsafe *const u8, n: usize) {
    case_no += 1
    var err      = ParseError { at: 0, kind: ParseErrorKind::None }
    var got      = parse_f64(b, n, &err)
    var o: f64   = 0.0
    var consumed: usize = 0
    var rc: i32  = 0
    unsafe { rc = oracle_f64_from(b, n, unsafe &o, unsafe &consumed) }
    var ok = false
    if rc == 0 && consumed == n {
        ok = err.kind == ParseErrorKind::None && got.to_bits() == o.to_bits()
    } else if rc == 2 && consumed == n {
        ok = err.kind == ParseErrorKind::Overflow || (err.kind == ParseErrorKind::None && got.to_bits() == 0)
    }

    if !ok {
        fail(case_no, f"f64 '{show(b, n)}': got {got.to_bits():#x} kind {err.kind as u8}; from_chars {o.to_bits():#x} rc {rc}")
    }
}

fn check32(b: unsafe *const u8, n: usize) {
    case_no += 1
    var err      = ParseError { at: 0, kind: ParseErrorKind::None }
    var got      = parse_f32(b, n, &err)
    var o: f32   = 0.0
    var consumed: usize = 0
    var rc: i32  = 0
    unsafe { rc = oracle_f32_from(b, n, unsafe &o, unsafe &consumed) }
    var ok = false
    if rc == 0 && consumed == n {
        ok = err.kind == ParseErrorKind::None && got.to_bits() == o.to_bits()
    } else if rc == 2 && consumed == n {
        ok = err.kind == ParseErrorKind::Overflow || (err.kind == ParseErrorKind::None && got.to_bits() == 0)
    }

    if !ok {
        fail(case_no, f"f32 '{show(b, n)}': got {got.to_bits():#x} kind {err.kind as u8}; from_chars {o.to_bits():#x} rc {rc}")
    }
}

fn check_both(b: unsafe *const u8, n: usize) {
    check64(b, n)
    check32(b, n)
}

/// Every spelling of `w * 10^q` the header lists.
fn spellings(w: u64, q: i64) {
    var buf: [u8; 128]
    var unsafe *b = unsafe &buf[0]
    var digits    = w as string
    var nd        = digits.size()

    // "w" "e" q
    var n = put_text(b, 0, digits)
    n = put_text(b, n, f"e{q}")
    check_both(b, n)

    // The point after the first digit: "d.ddd" "e" (q + nd - 1).
    if nd > 1 {
        n    = put_text(b, 0, digits)
        for var i = nd; i > 1; --i {
            buf[i] = buf[i - 1]
        }

        buf[1] = 46
        n      = put_text(b, nd + 1, f"e{q + (nd as i64) - 1}")
        check_both(b, n)
    }

    // Behind leading zeros: "0.000…w" "e" (q + nd + z), past 19 digits.
    var z = if nd >= 19 => 4usize else => 22 - nd
    n = put_text(b, 0, "0.")
    n = put_zeros(b, n, z)
    n = put_text(b, n, digits)
    n = put_text(b, n, f"e{q + (nd as i64) + (z as i64)}")
    check_both(b, n)

    // With trailing zeros: "w000…" "e" (q - z), past 19 digits.
    n = put_text(b, 0, digits)
    n = put_zeros(b, n, z)
    n = put_text(b, n, f"e{q - (z as i64)}")
    check_both(b, n)

    // A point and trailing fraction zeros: "w.000…" "e" q.
    n = put_text(b, 0, digits)
    n = put_text(b, n, ".")
    n = put_zeros(b, n, z)
    n = put_text(b, n, f"e{q}")
    check_both(b, n)
}

fn main() -> i32 {
    var edges: [u64; 8] = [
        1u64 << 53, 1u64 << 24, 9999999999999999u64, 10000000000000000u64,
        99999999999999999u64, 9999999u64, 10000000u64, 1u64,
    ]
    for var e: usize = 0; e < 8; ++e {
        for var d: i64 = -3; d <= 3; ++d {
            var w = ((edges[e] as i64) + d) as u64
            if (w as i64) <= 0 {
                continue
            }

            for var q: i64 = -26; q <= 26; ++q {
                spellings(w, q)
            }
        }
    }

    // Odd significands just under each edge, where the quotient is inexact.
    var r = Rng { s: 0xfa57fa57u64 }
    for var k = 0; k < 20000; ++k {
        var top  = if (k & 1) == 0 => (1u64 << 53) else => (1u64 << 24)
        var w    = top - (rng_below(&r, 1000000) | 1)
        var q    = (rng_below(&r, 53) as i64) - 26
        var buf: [u8; 64]
        var unsafe *b = unsafe &buf[0]
        var n    = put_text(b, 0, w as string)
        n = put_text(b, n, f"e{q}")
        check_both(b, n)
    }

    if first_failure == 0 {
        println(f"ok {case_no}")
    }

    return first_failure
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
