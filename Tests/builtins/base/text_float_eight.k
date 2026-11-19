// The float parser's eight-digits-at-a-time step: a byte just outside the
// digit range ('/' and ':', and every other non-digit byte) at any of the
// eight places of a run stops the number there, in the integer part and in
// the fraction, and runs of every length around eight read as their value.

import std::io::*
import self::inputs::numtext_support::*

fn main() -> i32 {
    var no: i32 = 0
    var buf: [u8; 40]
    var unsafe *b = unsafe &buf[0]
    var err = ParseError { at: 0, kind: ParseErrorKind::None }

    // "12345678901234567" with one byte replaced, in the integer part
    // ("d...d") and after "0." in the fraction.
    for var frac = 0; frac < 2; frac++ {
        var lead: usize = if frac == 1 => 2 else => 0
        for var pos: usize = 0; pos < 17; pos++ {
            for var bad: u32 = 0; bad < 256; bad++ {
                if bad >= 48 && bad <= 57 {
                    continue
                }

                no += 1
                buf[0] = 48
                buf[1] = 46
                for var i: usize = 0; i < 17; i++ {
                    buf[lead + i] = (49 + (i % 9)) as u8
                }

                buf[lead + pos] = bad as u8
                var n = lead + 17
                parse_f64(b, n, &err)
                // The number ends at the bad byte unless that byte is where
                // the number may go on: '.' after an integer part, or 'e'
                // / 'E' followed by digits.
                // A leading sign is part of the number too.
                var ends_there = !(bad == 46 && frac == 0) && bad != 101 && bad != 69
                    && !(pos == 0 && frac == 0 && (bad == 43 || bad == 45))
                if ends_there && (err.kind != ParseErrorKind::Trailing || err.at != (lead + pos) as u32) {
                    if !(pos == 0 && frac == 0 && err.kind == ParseErrorKind::InvalidChar) {
                        fail(no, f"byte {bad} at {pos} (fraction {frac}): kind {err.kind as u8} at {err.at}")
                    }
                }
            }
        }
    }

    // Runs of 1 to 20 nines, integer and fraction: the value is exact.
    for var len: usize = 1; len <= 20; len++ {
        no += 1
        for var i: usize = 0; i < len; i++ {
            buf[i] = 57
        }

        var v = parse_f64(b, len, &err)
        var want = 1.0
        for var i: usize = 0; i < len; i++ {
            want = want * 10.0
        }

        // 10^len - 1 rounds to 10^len once it no longer fits 53 bits.
        var w = if len <= 15 => want - 1.0 else => want
        if err.kind != ParseErrorKind::None || (len <= 15 && v != w) {
            fail(no, f"{len} nines read as {v}")
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
