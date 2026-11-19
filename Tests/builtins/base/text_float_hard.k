// Directed float cases from tests/hard_cases.h (gen_hard_cases.py computes
// the expected results with exact rational arithmetic): every power of two
// and its neighbours, powers of ten, exact halfway points and a hair either
// side of them, inputs of up to a thousand digits where a digit beyond the
// 768th decides, and the limits of both types.
//
// An expected infinity means the parse must report Overflow.

ffi "c++" import "inputs/hard_cases.h"

import std::io::*
import self::inputs::numtext_support::*

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

/// A long input, cut for the failure message.
fn brief(p: unsafe *const u8, n: usize) -> string {
    if n <= 60 {
        return show(p, n)
    }

    return f"{show(p, 60)}... ({n} bytes)"
}

fn main() -> i32 {
    var err = ParseError { at: 0, kind: ParseErrorKind::None }
    var count: usize = 0
    unsafe { count = hard_parse_count() }

    // Cases 1 and 2: text to f64, fast and exact; 3 and 4: text to f32.
    for var i: usize = 0; i < count; ++i {
        var t: unsafe *const u8 = unsafe hard_parse_text(i)
        var n:   usize = 0
        var w64: u64 = 0
        var w32: u32 = 0
        unsafe {
            n   = hard_parse_len(i)
            w64 = hard_parse_f64(i)
            w32 = hard_parse_f32(i)
        }

        var over64 = (w64 & 0x7FFFFFFFFFFFFFFF) == 0x7FF0000000000000
        var g = parse_f64(t, n, &err)
        if (over64 && err.kind != ParseErrorKind::Overflow) || (!over64 && (err.kind != ParseErrorKind::None || g.to_bits() != w64)) {
            fail(1, f"#{i} parse_f64('{brief(t, n)}') gave {g.to_bits():#x} kind {err.kind as u8}, want {w64:#x}")
        }

        g = parse_f64_exact(t, n, &err)
        if (over64 && err.kind != ParseErrorKind::Overflow) || (!over64 && (err.kind != ParseErrorKind::None || g.to_bits() != w64)) {
            fail(2, f"#{i} parse_f64_exact('{brief(t, n)}') gave {g.to_bits():#x} kind {err.kind as u8}, want {w64:#x}")
        }

        var over32 = (w32 & 0x7FFFFFFF) == 0x7F800000
        var h = parse_f32(t, n, &err)
        if (over32 && err.kind != ParseErrorKind::Overflow) || (!over32 && (err.kind != ParseErrorKind::None || h.to_bits() != w32)) {
            fail(3, f"#{i} parse_f32('{brief(t, n)}') gave {h.to_bits():#x} kind {err.kind as u8}, want {w32:#x}")
        }

        h = parse_f32_exact(t, n, &err)
        if (over32 && err.kind != ParseErrorKind::Overflow) || (!over32 && (err.kind != ParseErrorKind::None || h.to_bits() != w32)) {
            fail(4, f"#{i} parse_f32_exact('{brief(t, n)}') gave {h.to_bits():#x} kind {err.kind as u8}, want {w32:#x}")
        }

        if first_failure != 0 && i > 40 {
            break
        }
    }

    // Case 5: f64 to text, the exact bytes; and with a sign.
    var buf: [u8; 32]
    var unsafe *b = unsafe &buf[0]
    unsafe { count = hard_print64_count() }
    for var i: usize = 0; i < count; ++i {
        var t: unsafe *const u8 = unsafe hard_print64_text(i)
        var n:    usize = 0
        var bits: u64 = 0
        unsafe {
            n    = hard_print64_len(i)
            bits = hard_print64_bits(i)
        }

        var got = f64_to_text(__builtin_bitcast<f64, u64>(bits), b)
        if !same(b, got, t, n) {
            fail(5, f"f64 {bits:#x} printed '{show(b, got)}', want '{show(t, n)}'")
        }

        got = f64_to_text(__builtin_bitcast<f64, u64>(bits | 0x8000000000000000), b)
        var rest: unsafe *const u8 = unsafe &buf[1]
        if got != n + 1 || buf[0] != 45 || !same(rest, got - 1, t, n) {
            fail(5, f"f64 -{bits:#x} printed '{show(b, got)}', want '-{show(t, n)}'")
        }
    }

    // Case 6: f32 to text.
    unsafe { count = hard_print32_count() }
    for var i: usize = 0; i < count; ++i {
        var t: unsafe *const u8 = unsafe hard_print32_text(i)
        var n:    usize = 0
        var bits: u64 = 0
        unsafe {
            n    = hard_print32_len(i)
            bits = hard_print32_bits(i)
        }

        var got = f32_to_text(__builtin_bitcast<f32, u32>(bits as u32), b)
        if !same(b, got, t, n) {
            fail(6, f"f32 {bits:#x} printed '{show(b, got)}', want '{show(t, n)}'")
        }
    }

    if first_failure == 0 {
        println("ok")
    }

    return first_failure
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: ok
// The 32-bit arithmetic path, forced on this host.
// RUN: %kairo %s -O2 -DKAIRO_NUMTEXT_NARROW -o %t.narrow.exe --cache-dir %t.dn
// RUN: %t.narrow.exe | %FileCheck %s
