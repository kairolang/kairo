/// --- The Kairo Project --- Tests/NumericConformance/integer_128bit_range.k --- ///
///
/// The 64-to-128-bit crossing. Above 2^64 a value no longer fits a machine
/// register, so it is carried in two limbs and every operation on it is
/// synthesised from narrower ones. That synthesis is where carries get dropped,
/// doubled, or written to the wrong limb, and the result of each of those is a
/// number rather than a crash.
///
/// This is not a hypothetical risk for Kairo specifically. The BigInt multiply
/// in Compiler/Lexer/Immediate.k splits its limbs with `& 0xFFFFFFFF`, and
/// under stage 0 that mask was a no-op for roughly twenty uses, because of the
/// bug in integer_32bit_band.k. The masks are now built rather than spelled,
/// but "the limb arithmetic is correct" is an assumption this file exists to
/// stop being an assumption.
///
/// STAGE 0 TODAY: PASSES. Note that every value here is BUILT by shifting, not
/// spelled -- stage 0 rejects any literal at or above 2^64 outright, so a file
/// spelling them could not be compiled there at all. The literal form is tested
/// separately in integer_literal_too_large.k.
///
/// DECISION: none. Two's-complement arithmetic at a wider width.
///

fn main() -> i32 {
    var one: u128 = 1;
    var two64: u128 = one << 64;

    // ---- checks 1-3: the value below the crossing ---------------------------
    // 2^64 - 1: one limb, saturated, the largest value that still fits 64 bits.
    // Built by doubling the top bit rather than as `(1 << 64) - 1` so that the
    // construction does not depend on the crossing it is meant to sit below.
    var top64: u128 = one << 63;
    var u64_max: u128 = top64 + (top64 - 1);
    if u64_max != (two64 - 1)  { return 1; }
    if (u64_max < two64) != true { return 2; }
    // The low limb is all ones and the high limb is empty.
    if (u64_max >> 64) != 0 { return 3; }

    // ---- checks 4-6: the crossing itself ------------------------------------
    // 2^64. The carry must land in the high limb and the low limb must be zero.
    // A dropped carry gives 0 here; a carry written to the wrong limb gives 1.
    // Both are ordinary-looking small numbers, which is why all three of the
    // high limb, the low limb, and the whole value are checked separately.
    if (two64 >> 64) != 1                     { return 4; }
    if (two64 - (two64 >> 64 << 64)) != 0     { return 5; }
    if (u64_max + 1) != two64                 { return 6; }

    // ---- checks 7-8: the carry must not consume a digit ---------------------
    // 2^64 + 1 has BOTH limbs set to 1. A carry implementation that clears the
    // low limb on carry-out passes checks 4-6 and fails here.
    var two64_plus1: u128 = two64 + 1;
    if (two64_plus1 >> 64) != 1                        { return 7; }
    if (two64_plus1 - (two64_plus1 >> 64 << 64)) != 1  { return 8; }

    // ---- checks 9-10: borrow across the limb boundary -----------------------
    // The reverse direction. Subtracting 1 from 2^64 must borrow from the high
    // limb and leave the low limb saturated. A missing borrow leaves the high
    // limb set and gives a value about 2^64 too large.
    if (two64 - 1) != u64_max        { return 9; }
    if ((two64 - 1) >> 64) != 0      { return 10; }

    // ---- checks 11-12: multiplication across the boundary -------------------
    // 2^32 * 2^32 == 2^64. At 64 bits this wraps to zero (see
    // overflow_and_wraparound.k check 14); at 128 bits it must NOT, and that
    // difference is the whole reason for having a wider type.
    var two32: u128 = one << 32;
    if (two32 * two32) != two64 { return 11; }
    // And one step further, which needs the high limb to hold a real value
    // rather than just a carry bit.
    if ((two32 * two32) * two32) != (one << 96) { return 12; }

    // ---- checks 13-14: the top of the range ---------------------------------
    // 2^127, the 128-bit sign boundary, and 2^128 - 1 with both limbs
    // saturated. Every bit of the latter is load-bearing.
    var top128: u128 = one << 127;
    if (top128 >> 127) != 1 { return 13; }
    var u128_max: u128 = top128 + (top128 - 1);
    if (u128_max + 1) != 0 { return 14; }

    // ---- check 15: both limbs of the maximum are saturated ------------------
    // Stated as two separate limb inspections rather than trusting check 14.
    // A value that is all ones in the low limb and all ones in the high limb
    // wraps to zero on increment; so does a value that is all ones in the low
    // limb and garbage in the high limb, if the increment is only looking at
    // the low one.
    if (u128_max >> 64) != u64_max                      { return 15; }
    if (u128_max - (u128_max >> 64 << 64)) != u64_max   { return 16; }

    return 0;
}
