// Explicit conversions into and out of the extended widths at their edge
// values, run: f80 (x87, 64-bit significand), f128 (binary128, 113-bit
// significand), i128/u128. Every one is E (conversion-lattice.mdx R5: no
// extended type is ever W), so each is spelled with `as`.
//
//   - u64 and i64 extremes are exact in f80 and f128 (64 <= 64, 64 <= 113),
//     so they round-trip; i128 max is not, and rounds up to 2^127;
//   - f64 -> f80/f128 is exact, so going back is the identity, while a
//     decimal read at the wide format (0.1f128) is NOT the f64 0.1 widened;
//   - f128/f80 -> f64 and f128 -> f80 round to nearest;
//   - in-range f128 -> int truncates toward zero.
//
// Only where both types exist: x86_64 Linux (primitives.mdx, f80 follows the
// target's `long double`). Operands go through id_ calls (runtime at -O0).

import std::io::println

fn id_i64(x: i64) -> i64 { return x; }
fn id_u64(x: u64) -> u64 { return x; }
fn id_i128(x: i128) -> i128 { return x; }
fn id_f64(x: f64) -> f64 { return x; }
fn id_f80(x: f80) -> f80 { return x; }
fn id_f128(x: f128) -> f128 { return x; }

fn main() -> i32 {
    var bad = 0;
    var umax = id_u64(18446744073709551615);
    var imin = id_i64(-9223372036854775807 - 1);

    // --- 64-bit integers are exact in both wide floats --------------------------
    if ((umax as f80) as u64) != umax { println("u64 max via f80"); bad += 1; }
    if ((imin as f80) as i64) != imin { println("i64 min via f80"); bad += 1; }
    if ((umax as f128) as u64) != umax { println("u64 max via f128"); bad += 1; }
    if ((imin as f128) as i64) != imin { println("i64 min via f128"); bad += 1; }

    // --- i128 max is not: 2^127 - 1 rounds to 2^127 ----------------------------------
    var i128max = id_i128(170141183460469231731687303715884105727);
    if (i128max as f128) != 170141183460469231731687303715884105728.0f128 { println("i128 max as f128"); bad += 1; }
    if (id_i128(-1) as f128) != -1.0f128 { println("i128 -1 as f128"); bad += 1; }
    if (id_f128(-2.5f128) as i32) != -2 { println("f128 -2.5 as i32"); bad += 1; }
    // 10^30 is 2^30 * 5^30, and 5^30 < 2^70 fits the significand: exact.
    if (id_f128(1.0e30f128) as i128) != 1000000000000000000000000000000 { println("1e30f128 as i128"); bad += 1; }
    if (id_f64(1.0e30) as i128) != 1000000000000000019884624838656 { println("1e30f64 as i128"); bad += 1; }

    // --- f64 widens exactly, the decimal does not ----------------------------------
    var tenth = id_f64(0.1);
    if ((tenth as f128) as f64) != tenth { println("f64 via f128"); bad += 1; }
    if ((tenth as f80) as f64) != tenth { println("f64 via f80"); bad += 1; }
    if (tenth as f128) == 0.1f128 { println("0.1f64 as f128 is not 0.1f128"); bad += 1; }
    if (tenth as f80) == 0.1f80 { println("0.1f64 as f80 is not 0.1f80"); bad += 1; }

    // --- and narrows to nearest ---------------------------------------------------
    if (id_f128(0.1f128) as f64) != 0.1 { println("0.1f128 as f64"); bad += 1; }
    if (id_f80(0.1f80) as f64) != 0.1 { println("0.1f80 as f64"); bad += 1; }
    if (id_f128(0.1f128) as f80) != 0.1f80 { println("0.1f128 as f80"); bad += 1; }
    if (id_f80(0.5f80) as f128) != 0.5f128 { println("0.5f80 as f128"); bad += 1; }
    var inf = id_f64(1.0) / id_f64(0.0);
    if (id_f128(1.0e400f128) as f64) != inf { println("1e400f128 as f64 is inf"); bad += 1; }

    println(f"bad {bad}");
    return bad;
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, host-x86_64, host-linux
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: bad 0
