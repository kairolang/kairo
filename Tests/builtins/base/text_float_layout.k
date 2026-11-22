// f64 and f32 to text: the placement of digits, point, zeros and exponent.
// Each value's text is compared with a reference layout written here from
// the rules (digits made one at a time), and std::from_chars must read it
// back as the same bits. The values are k * 10^j for significands of 1 to
// 17 digits and j from -30 to 25, so every notation shows up with every
// digit count: whole numbers with zeros up to the point's place, points
// after each digit, "0.000ddd", and the exponent form on both sides.

ffi "c++" import "inputs/oracle.h"

import std::io::*
import self::inputs::numtext_support::*

var case_no: i32 = 0

/// The rules: e is the exponent of the first digit; plain notation when
/// -4 <= e < `fixed_below`, otherwise d[.ddd]e[+-]XX with at least two
/// exponent digits; a whole number has no point.
fn reference(out: unsafe *u8, neg: bool, sig: u64, exp: i32, fixed_below: i32) -> usize {
    var digits: [u8; 24]
    var n: usize = 0
    var s        = sig
    while s > 0 {
        digits[n] = (48 + s % 10) as u8
        s = s / 10
        n += 1
    }

    // digits[] is last digit first; d(i) is the i-th digit from the left.
    var o: usize = 0
    if neg {
        out[o] = 45
        o += 1
    }

    var e = exp + (n as i32) - 1
    if e < -4 || e >= fixed_below {
        out[o] = digits[n - 1]
        o += 1
        if n > 1 {
            out[o] = 46
            o += 1
            for var i: usize = 1; i < n; ++i {
                out[o] = digits[n - 1 - i]
                o += 1
            }
        }

        out[o] = 101
        o += 1
        out[o] = if e < 0 => 45u8 else => 43u8
        o += 1
        var a = if e < 0 => 0 - e else => e
        if a >= 100 {
            out[o] = (48 + a / 100) as u8
            o += 1
        }

        out[o]     = (48 + (a / 10) % 10) as u8
        out[o + 1] = (48 + a % 10) as u8
        return o + 2
    }

    if e < 0 {
        out[o]     = 48
        out[o + 1] = 46
        o += 2
        for var i: i32 = 0; i < 0 - e - 1; ++i {
            out[o] = 48
            o += 1
        }
    }

    for var i: usize = 0; i < n; ++i {
        if e >= 0 && (i as i32) == e + 1 {
            out[o] = 46
            o += 1
        }

        out[o] = digits[n - 1 - i]
        o += 1
    }

    for var i: i32 = n as i32; i < e + 1; ++i {
        out[o] = 48
        o += 1
    }

    return o
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

fn check64(bits: u64) {
    var mag = bits & 0x7FFFFFFFFFFFFFFF
    if mag == 0 || mag >= 0x7FF0000000000000 {
        return
    }

    case_no += 1
    var buf:  [u8; 64]
    var want: [u8; 64]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]
    var n  = f64_to_text(__builtin_bitcast<f64, u64>(bits), b)
    var d  = f64_to_decimal(mag)
    var wn = reference(w, mag != bits, d.sig, d.exp, 17)
    if !same(b, n, w, wn) {
        fail(case_no, f"f64 {bits:#x}: '{show(b, n)}', want '{show(w, wn)}'")
        return
    }

    var back: f64       = 0.0
    var consumed: usize = 0
    var rc: i32         = 0
    unsafe { rc = oracle_f64_from(b, n, unsafe &back, unsafe &consumed) }
    if rc != 0 || consumed != n || back.to_bits() != bits {
        fail(case_no, f"f64 {bits:#x}: from_chars read '{show(b, n)}' as {back.to_bits():#x}")
    }
}

fn check32(bits: u32) {
    var mag = bits & 0x7FFFFFFF
    if mag == 0 || mag >= 0x7F800000 {
        return
    }

    case_no += 1
    var buf:  [u8; 64]
    var want: [u8; 64]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]
    var n  = f32_to_text(__builtin_bitcast<f32, u32>(bits), b)
    var d  = f32_to_decimal(mag)
    var wn = reference(w, mag != bits, d.sig, d.exp, 9)
    if !same(b, n, w, wn) {
        fail(case_no, f"f32 {bits:#x}: '{show(b, n)}', want '{show(w, wn)}'")
        return
    }

    var back: f32       = 0.0
    var consumed: usize = 0
    var rc: i32         = 0
    unsafe { rc = oracle_f32_from(b, n, unsafe &back, unsafe &consumed) }
    if rc != 0 || consumed != n || back.to_bits() != bits {
        fail(case_no, f"f32 {bits:#x}: from_chars read '{show(b, n)}' as {back.to_bits():#x}")
    }
}

fn main() -> i32 {
    var ks: [u64; 20] = [
        1, 2, 5, 9, 12, 99, 123, 1001, 12345, 999999, 1234567, 16777215, 99999999,
        123456789, 1234567891, 123456789012, 98765432109876, 1234567890123456,
        9007199254740991, 12345678901234567,
    ]
    for var i: usize = 0; i < 20; ++i {
        for var j: i64 = -30; j <= 25; ++j {
            var t = f"{ks[i]}e{j}"
            var v = f64::from_str(t) ?? 0.0
            check64(v.to_bits())
            check64(v.to_bits() | 0x8000000000000000)
            var f = f32::from_str(t) ?? 0.0
            check32(f.to_bits())
            check32(f.to_bits() | 0x80000000)
        }
    }

    var r = Rng { s: 0x1a40u64 }
    for var i = 0; i < 200000; ++i {
        var x = rng_next(&r)
        check64(x)
        check32(x as u32)
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
