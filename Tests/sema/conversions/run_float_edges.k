// Explicit float conversions at their edge values, run (casting.mdx Float to
// integer / Integer to float, conversion-lattice.mdx R3/R4, primitives.mdx
// Floating-Point). In range only: what an OUT-of-range float -> int must do
// (saturate) is xfail_float_int_saturate.k, because today it does not.
//
//   - float -> int truncates toward zero, both signs;
//   - int -> float rounds to nearest, ties to even (2^53 + 1 -> 2^53,
//     2^53 + 3 -> 2^53 + 4; 16777217 -> 16777216 in f32; 2049 -> 2048 in
//     f16; 257 -> 256 in bf16);
//   - float -> narrower float rounds to nearest; past the target's range it
//     is inf (IEEE 754, primitives.mdx: overflow produces inf); NaN stays NaN;
//   - the W pairs (f16 -> f32, f32 -> f64, bf16 -> f32) are exact, so a
//     round trip back through `as` is the identity.
//
// Every operand goes through an id_ call: the conversions are the runtime
// ones at -O0, not clang's constant folding. "bad 0" or the failing labels.

import std::io::println

fn id_i32(x: i32) -> i32 { return x; }
fn id_i64(x: i64) -> i64 { return x; }
fn id_u32(x: u32) -> u32 { return x; }
fn id_u64(x: u64) -> u64 { return x; }
fn id_f16(x: f16) -> f16 { return x; }
fn id_bf16(x: bf16) -> bf16 { return x; }
fn id_f32(x: f32) -> f32 { return x; }
fn id_f64(x: f64) -> f64 { return x; }

fn main() -> i32 {
    var bad = 0;

    // --- float -> int, in range: toward zero ------------------------------------
    if (id_f64(3.9) as i32) != 3 { println("3.9 as i32"); bad += 1; }
    if (id_f64(-2.7) as i32) != -2 { println("-2.7 as i32"); bad += 1; }
    if (id_f64(-0.5) as i32) != 0 { println("-0.5 as i32"); bad += 1; }
    if (id_f64(255.9) as u8) != 255 { println("255.9 as u8"); bad += 1; }
    if (id_f64(0.99) as u64) != 0 { println("0.99 as u64"); bad += 1; }
    if (id_f64(2147483647.0) as i32) != 2147483647 { println("i32 max as f64 as i32"); bad += 1; }
    if (id_f64(-2147483648.0) as i32) != -2147483648 { println("i32 min as f64 as i32"); bad += 1; }
    if (id_f32(-128.75f32) as i8) != -128 { println("f32 -128.75 as i8"); bad += 1; }
    if (id_f16(-3.5f16) as i16) != -3 { println("f16 -3.5 as i16"); bad += 1; }
    if (id_bf16(7.5bf16) as u8) != 7 { println("bf16 7.5 as u8"); bad += 1; }
    if (id_f64(1.0e18) as i64) != 1000000000000000000 { println("1e18 as i64"); bad += 1; }

    // --- int -> float: nearest, ties to even -----------------------------------------
    if (id_i64(9007199254740993) as f64) != 9007199254740992.0 { println("2^53+1 as f64"); bad += 1; }
    if (id_i64(9007199254740995) as f64) != 9007199254740996.0 { println("2^53+3 as f64"); bad += 1; }
    if (id_i32(16777217) as f32) != 16777216.0f32 { println("2^24+1 as f32"); bad += 1; }
    if (id_i32(2049) as f16) != 2048.0f16 { println("2049 as f16"); bad += 1; }
    if (id_i32(257) as bf16) != 256.0bf16 { println("257 as bf16"); bad += 1; }
    if (id_u64(18446744073709551615) as f64) != 18446744073709551616.0 { println("u64 max as f64"); bad += 1; }
    if (id_u32(4294967295) as f32) != 4294967296.0f32 { println("u32 max as f32"); bad += 1; }
    if (id_i32(-1) as f64) != -1.0 { println("-1 as f64"); bad += 1; }
    if (id_i64(-9223372036854775807 - 1) as f64) != -9223372036854775808.0 { println("i64 min as f64"); bad += 1; }

    // --- float -> float ------------------------------------------------------------
    if (id_f64(0.1) as f32) != 0.1f32 { println("0.1 as f32 rounds to nearest"); bad += 1; }
    if (id_f64(65504.0) as f16) != 65504.0f16 { println("f16 max survives"); bad += 1; }
    var inf = id_f64(1.0) / id_f64(0.0);
    if (id_f64(1.0e40) as f32) != (inf as f32) { println("1e40 as f32 is inf"); bad += 1; }
    if (id_f64(1.0e5) as f16) != (inf as f16) { println("1e5 as f16 is inf"); bad += 1; }
    if (id_f64(-1.0e40) as f32) != (-inf as f32) { println("-1e40 as f32 is -inf"); bad += 1; }
    var nan = id_f64(0.0) / id_f64(0.0);
    var nan32 = nan as f32;
    if nan32 == nan32 { println("NaN as f32 is NaN"); bad += 1; }
    if (id_f64(1.0e-50) as f32) != 0.0f32 { println("1e-50 as f32 underflows to 0"); bad += 1; }

    // --- the W pairs are exact: the way back is the identity ---------------------------
    if ((id_f32(0.1f32) as f64) as f32) != 0.1f32 { println("f32 via f64"); bad += 1; }
    if (id_f32(0.1f32) as f64) != 0.100000001490116119384765625 { println("0.1f32 as f64 exact"); bad += 1; }
    if ((id_f16(0.1f16) as f32) as f16) != 0.1f16 { println("f16 via f32"); bad += 1; }
    if ((id_bf16(0.1bf16) as f32) as bf16) != 0.1bf16 { println("bf16 via f32"); bad += 1; }
    if ((id_f16(65504.0f16) as f64) as f16) != 65504.0f16 { println("f16 max via f64"); bad += 1; }

    println(f"bad {bad}");
    return bad;
}

// --- lit wiring -----------------------------------------------------------
// -A SC031W: the W round trips spell their widening `as` on purpose.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -A SC031W -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: bad 0
