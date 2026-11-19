// Integer <-> text against the C++ standard library (std::to_chars and
// std::from_chars, through tests/oracle.h): the same bytes for every value,
// and the same verdict and value for every text.
//
// from_chars takes no leading '+', so the generated texts have none.

ffi "c++" import "inputs/oracle.h"

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

/// The verdict the oracle's result maps to: 0 a value, else the kind.
fn verdict(rc: i32, consumed: usize, n: usize) -> ParseErrorKind {
    if rc == 1 {
        return if n == 0 => ParseErrorKind::Empty else => ParseErrorKind::InvalidChar
    }

    if consumed < n {
        return ParseErrorKind::Trailing
    }

    return if rc == 2 => ParseErrorKind::Overflow else => ParseErrorKind::None
}

/// A text that is mostly a number: up to 24 digits, weighted toward the
/// lengths where the range check decides, with an occasional sign and an
/// occasional stray byte anywhere.
fn make_text(r: *Rng, out: unsafe *u8) -> usize {
    var n: usize = 0
    if rng_below(r, 3) == 0 {
        out[n] = 45
        n += 1
    }

    var nd = rng_below(r, 25)
    if rng_below(r, 2) == 0 {
        nd = 17 + rng_below(r, 5)
    }

    // Half of the long ones start at the limit's own leading digits.
    var near = rng_below(r, 2) == 0
    for var i: u64 = 0; i < nd; ++i {
        var d = rng_below(r, 10)
        if near && i == 0 {
            d = if rng_below(r, 2) == 0 => 1u64 else => 9u64
        }

        if near && i == 1 {
            d = if rng_below(r, 2) == 0 => 8u64 else => 2u64
        }

        out[n] = (48 + d) as u8
        n += 1
    }

    if rng_below(r, 8) == 0 {
        const STRAY: [const u8;] = b" x-+.e\x00:/"
        var at = rng_below(r, (n as u64) + 1) as usize
        var i  = n
        while i > at {
            out[i] = out[i - 1]
            i -= 1
        }

        out[at] = STRAY[rng_below(r, STRAY.size() as u64) as usize]
        // A leading '+' is the one form the two sides read differently.
        if at == 0 && out[0] == 43 {
            out[0] = 120
        }

        n += 1
    }

    return n
}

fn main() -> i32 {
    var rng = Rng { s: 0x1234567887654321 }
    var buf:  [u8; 64]
    var want: [u8; 64]
    var unsafe *b = unsafe &buf[0]
    var unsafe *w = unsafe &want[0]

    // Case 1: value to text.
    for var i: i32 = 0; i < 1000000; ++i {
        var v    = rng_next(&rng)
        var bits = (rng_below(&rng, 64) + 1) as u32
        if bits < 64 {
            v = v >> (64 - bits)
        }

        var wn: i32 = 0
        unsafe { wn = oracle_u64_text(v, w) }
        var r = u64_to_text(v, b, 20)
        var unsafe *t = unsafe &buf[r.start]
        if !same(t, r.len, w, wn as usize) {
            fail(1, f"u64_to_text({v}) gave '{show(t, r.len)}'")
        }

        var s = v as i64
        if (i & 1) != 0 {
            s = 0 - s
        }

        unsafe { wn = oracle_i64_text(s, w) }
        r = i64_to_text(s, b, 20)
        t = unsafe &buf[r.start]
        if !same(t, r.len, w, wn as usize) {
            fail(1, f"i64_to_text({s}) gave '{show(t, r.len)}'")
        }
    }

    // Case 2: text to value.
    for var i: i32 = 0; i < 1000000; ++i {
        var n   = make_text(&rng, b)
        var err = ParseError { at: 0, kind: ParseErrorKind::None }

        var ou: u64 = 0
        var consumed: usize = 0
        var rc: i32 = 0
        unsafe { rc = oracle_u64_from(b, n, unsafe &ou, unsafe &consumed) }
        var gu = parse_u64(b, n, &err)
        var wk = verdict(rc, consumed, n)
        if err.kind != wk || (wk == ParseErrorKind::None && gu != ou) || (wk == ParseErrorKind::Trailing && err.at != (consumed as u32)) {
            fail(2, f"parse_u64('{show(b, n)}') gave {gu} kind {err.kind as u8} at {err.at}; oracle rc {rc} consumed {consumed} value {ou}")
        }

        var oi: i64 = 0
        unsafe { rc = oracle_i64_from(b, n, unsafe &oi, unsafe &consumed) }
        var gi = parse_i64(b, n, &err)
        wk = verdict(rc, consumed, n)
        if err.kind != wk || (wk == ParseErrorKind::None && gi != oi) || (wk == ParseErrorKind::Trailing && err.at != (consumed as u32)) {
            fail(2, f"parse_i64('{show(b, n)}') gave {gi} kind {err.kind as u8} at {err.at}; oracle rc {rc} consumed {consumed} value {oi}")
        }

        if first_failure != 0 {
            break
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
