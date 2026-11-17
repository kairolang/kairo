// f64 and f32 <-> text against the C++ standard library (std::to_chars and
// std::from_chars, through tests/oracle.h).
//
//   1, 2  the shortest digits and exponent equal to_chars' scientific form
//         (round-tripping alone would not show a digit too many);
//   3, 4  from_chars reads this printer's text back as the same bits;
//   5, 6  generated decimal strings give the bits from_chars gives, through
//         the fast parser and through the exact one.
//
// from_chars reports a number that rounds to zero or to infinity as out of
// range; here the first is zero and the second is Overflow.

ffi "c++" import "Inputs/oracle.h"

import std::io::*
import self::Inputs::numtext_support::*

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

/// `d` as to_chars writes its scientific form: `d[.ddd]e[+-]XX`.
fn scientific(d: FloatDecimal, out: unsafe *u8) -> usize {
    var digits: [u8; 20]
    var r = u64_to_text(d.sig, unsafe &digits[0], 20)
    var e = d.exp + (r.len as i32) - 1
    var o: usize = 0
    out[o] = digits[r.start]
    o += 1
    if r.len > 1 {
        out[o] = 46
        o += 1
        for var i: usize = 1; i < r.len; ++i {
            out[o] = digits[r.start + i]
            o += 1
        }
    }

    out[o] = 101
    out[o + 1] = if e < 0 => 45u8 else => 43u8
    o += 2
    if e < 0 {
        e = 0 - e
    }

    if e >= 100 {
        out[o] = (48 + e / 100) as u8
        o += 1
        e = e % 100
    }

    out[o]     = (48 + e / 10) as u8
    out[o + 1] = (48 + e % 10) as u8
    return o + 2
}

/// A decimal number: 1 to 40 digits (now and then several hundred), a point
/// anywhere or nowhere, and an exponent that puts the value anywhere from
/// far below the smallest subnormal to far above the largest finite.
fn make_decimal(r: *Rng, out: unsafe *u8, single: bool) -> usize {
    var n: usize = 0
    if rng_below(r, 4) == 0 {
        out[n] = 45
        n += 1
    }

    var nd = 1 + rng_below(r, 40)
    var pick = rng_below(r, 16)
    if pick == 0 {
        nd = 1 + rng_below(r, 900)
    } else if pick < 6 {
        nd = 15 + rng_below(r, 6)
    }

    var point = rng_below(r, nd + 2)          // nd + 1: no point
    for var i: u64 = 0; i < nd; ++i {
        if i == point {
            out[n] = 46
            n += 1
        }

        out[n] = (48 + rng_below(r, 10)) as u8
        n += 1
    }

    if rng_below(r, 4) != 0 {
        var span: u64 = if single => 60u64 else => 340u64
        var e = (rng_below(r, 2 * span) as i64) - (span as i64)
        // Keep the value's magnitude near e whatever the digit count is.
        if point < nd {
            e = e - (point as i64)
        } else {
            e = e - (nd as i64)
        }

        out[n] = if rng_below(r, 2) == 0 => 101u8 else => 69u8
        n += 1
        if e < 0 {
            out[n] = 45
            n += 1
            e = 0 - e
        }

        var tmp: [u8; 20]
        var t = u64_to_text(e as u64, unsafe &tmp[0], 20)
        for var i: usize = 0; i < t.len; ++i {
            out[n] = tmp[t.start + i]
            n += 1
        }
    }

    return n
}

fn main() -> i32 {
    var rng = Rng { s: 0x0123456789ABCDEF }
    var buf:  [u8; 1024]
    var want: [u8; 64]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    var consumed: usize = 0
    var rc: i32 = 0

    // Cases 1 and 3: f64.
    for var i: i32 = 0; i < ROUNDS; ++i {
        var bits = rng_next(&rng)
        var mag  = bits & 0x7FFFFFFFFFFFFFFF
        if mag >= 0x7FF0000000000000 || mag == 0 {
            continue
        }

        var v  = __builtin_bitcast<f64, u64>(bits)
        var wn: i32 = 0
        unsafe { wn = oracle_f64_sci(__builtin_bitcast<f64, u64>(mag), w) }
        var n = scientific(f64_to_decimal(mag), b)
        if !same(b, n, w, wn as usize) {
            fail(1, f"f64 bits {mag:#x}: digits '{show(b, n)}', to_chars '{show(w, wn as usize)}'")
            break
        }

        n = f64_to_text(v, b)
        var back: f64 = 0.0
        unsafe { rc = oracle_f64_from(b, n, unsafe &back, unsafe &consumed) }
        if rc != 0 || consumed != n || back.to_bits() != bits {
            fail(3, f"f64 bits {bits:#x}: from_chars read '{show(b, n)}' as {back.to_bits():#x} rc {rc}")
            break
        }
    }

    // Cases 2 and 4: f32.
    for var i: i32 = 0; i < ROUNDS; ++i {
        var bits = rng_next(&rng) as u32
        var mag  = bits & 0x7FFFFFFF
        if mag >= 0x7F800000 || mag == 0 {
            continue
        }

        var v  = __builtin_bitcast<f32, u32>(bits)
        var wn: i32 = 0
        unsafe { wn = oracle_f32_sci(__builtin_bitcast<f32, u32>(mag), w) }
        var n = scientific(f32_to_decimal(mag), b)
        if !same(b, n, w, wn as usize) {
            fail(2, f"f32 bits {mag:#x}: digits '{show(b, n)}', to_chars '{show(w, wn as usize)}'")
            break
        }

        n = f32_to_text(v, b)
        var back: f32 = 0.0
        unsafe { rc = oracle_f32_from(b, n, unsafe &back, unsafe &consumed) }
        if rc != 0 || consumed != n || back.to_bits() != bits {
            fail(4, f"f32 bits {bits:#x}: from_chars read '{show(b, n)}' as {back.to_bits():#x} rc {rc}")
            break
        }
    }

    // Case 5: decimal strings as f64.
    for var i: i32 = 0; i < 2000000; ++i {
        var n = make_decimal(&rng, b, false)
        var o: f64 = 0.0
        unsafe { rc = oracle_f64_from(b, n, unsafe &o, unsafe &consumed) }
        var fast = parse_f64(b, n, &err)
        var fk   = err.kind
        var slow = parse_f64_exact(b, n, &err)
        if fast.to_bits() != slow.to_bits() || fk != err.kind {
            fail(5, f"'{show(b, n)}': fast {fast.to_bits():#x} kind {fk as u8}, exact {slow.to_bits():#x} kind {err.kind as u8}")
            break
        }

        var ok = false
        if rc == 0 && consumed == n {
            ok = fk == ParseErrorKind::None && fast.to_bits() == o.to_bits()
        } else if rc == 2 && consumed == n {
            ok = fk == ParseErrorKind::Overflow || (fk == ParseErrorKind::None && (fast.to_bits() & 0x7FFFFFFFFFFFFFFF) == 0)
        }

        if !ok {
            fail(5, f"'{show(b, n)}': got {fast.to_bits():#x} kind {fk as u8}; from_chars {o.to_bits():#x} rc {rc} consumed {consumed}")
            break
        }
    }

    // Case 6: decimal strings as f32.
    for var i: i32 = 0; i < 2000000; ++i {
        var n = make_decimal(&rng, b, true)
        var o: f32 = 0.0
        unsafe { rc = oracle_f32_from(b, n, unsafe &o, unsafe &consumed) }
        var fast = parse_f32(b, n, &err)
        var fk   = err.kind
        var slow = parse_f32_exact(b, n, &err)
        if fast.to_bits() != slow.to_bits() || fk != err.kind {
            fail(6, f"'{show(b, n)}': fast {fast.to_bits():#x} kind {fk as u8}, exact {slow.to_bits():#x} kind {err.kind as u8}")
            break
        }

        var ok = false
        if rc == 0 && consumed == n {
            ok = fk == ParseErrorKind::None && fast.to_bits() == o.to_bits()
        } else if rc == 2 && consumed == n {
            ok = fk == ParseErrorKind::Overflow || (fk == ParseErrorKind::None && (fast.to_bits() & 0x7FFFFFFF) == 0)
        }

        if !ok {
            fail(6, f"'{show(b, n)}': got {fast.to_bits():#x} kind {fk as u8}; from_chars {o.to_bits():#x} rc {rc} consumed {consumed}")
            break
        }
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
