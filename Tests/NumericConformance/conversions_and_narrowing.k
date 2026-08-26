/// --- The Kairo Project --- Tests/NumericConformance/conversions_and_narrowing.k --- ///
///
/// Moving a value between widths and between signednesses. Every check here is
/// about a bit pattern that stays the same while its MEANING changes, which is
/// the category of bug that survives review: the number is not corrupted, it is
/// reinterpreted, and both the before and after look like legitimate values.
///
/// The stage-0 32-bit band bug is exactly this shape. `0xFFFFFFFF` has the
/// right 32 bits; typing them as signed turns 4294967295 into -1, and widening
/// that to 64 bits sign-extends it to 0xFFFFFFFFFFFFFFFF. Nothing is ever
/// truncated or lost. The value simply becomes a different number, twice, and
/// each step is individually defensible.
///
/// DECISION: none. Everything asserted here is two's-complement mechanics and
/// follows from the representation, not from a language choice.
///
/// STAGE 0 TODAY: PASSES.
///

fn main() -> i32 {
    // ---- checks 1-3: widening an unsigned value must zero-extend ------------
    // The high bits of the wider type must be zero, so the numeric value is
    // unchanged. This is the direction that has to be right for
    // Compiler/Support/Limits.k to work: U32_MAX is declared u32 precisely
    // because a u32 widens into a u64 expression correctly.
    //
    // NOTE the expected value for check 3 is BUILT, not spelled. Writing
    // `!= 4294967295` here looks obviously correct and is a trap: on a compiler
    // with the 32-bit band bug the expected value is itself -1, so the check
    // compares a correctly-widened 4294967295 against -1 and fails while
    // blaming the conversion. This file was written with that mistake in it and
    // stage 0 caught it. Never spell a band value on the right-hand side of a
    // check; see integer_32bit_band.k, which is the one file whose job is to
    // test the literal forms directly.
    var expect_u32_max: u64 = (static_cast::<u64>(1) << 32) - 1;

    var u8_top:  u8  = 255;
    var u16_top: u16 = 65535;
    var u32_top: u32 = static_cast::<u32>(expect_u32_max);
    if static_cast::<u64>(u8_top)  != 255            { return 1; }
    if static_cast::<u64>(u16_top) != 65535          { return 2; }
    if static_cast::<u64>(u32_top) != expect_u32_max { return 3; }

    // ---- checks 4-5: the widened value still behaves in 64-bit context ------
    // Not redundant with check 3. A value can widen to the right number and
    // still be compared wrongly if the comparison is emitted as signed. These
    // are the two shapes the compiler's bounds checks are written in.
    var big:   u64 = 5000000000;
    var small: u64 = 100;
    if (big > u32_top) != true    { return 4; }
    if (small > u32_top) != false { return 5; }

    // ---- checks 6-8: widening a signed NEGATIVE value must sign-extend ------
    // -1 at any width is all ones, and must still be -1 when widened. If these
    // return large positive numbers, the widening is zero-extending a signed
    // value, and every negative number in the compiler changes meaning the
    // moment it crosses a width boundary.
    var i8_neg:  i8  = -1;
    var i16_neg: i16 = -1;
    var i32_neg: i32 = -1;
    if static_cast::<i64>(i8_neg)  != -1 { return 6; }
    if static_cast::<i64>(i16_neg) != -1 { return 7; }
    if static_cast::<i64>(i32_neg) != -1 { return 8; }

    // ---- check 9: the reinterpretation that caused the stage-0 bug ----------
    // Signed -1 at 32 bits, read as unsigned 32 bits, is 4294967295. Read as
    // unsigned 64 bits after sign extension, it is 2^64 - 1.
    //
    // Both numbers below are "correct" for the bits involved; which one you get
    // depends entirely on the order of the widening and the reinterpretation.
    // Getting that order wrong is not a typo, it is the whole bug, so both
    // orders are pinned here rather than assumed.
    var neg_one_32: i32 = -1;
    // reinterpret at 32 bits first, then widen: 4294967295 (built, see above)
    if static_cast::<u64>(static_cast::<u32>(neg_one_32)) != expect_u32_max { return 9; }
    // widen at 64 bits first, then reinterpret: 18446744073709551615
    if static_cast::<u64>(static_cast::<i64>(neg_one_32)) != 0xFFFFFFFFFFFFFFFF { return 10; }

    // ---- checks 11-13: narrowing must truncate, not saturate ----------------
    // 0x1122334455667788 narrowed keeps the LOW bits. A compiler that saturates
    // instead would produce 255 / 65535 / 4294967295 here -- all plausible
    // numbers, none of them the right one.
    var wide: u64 = 0x1122334455667788;
    if static_cast::<u64>(static_cast::<u8>(wide))  != 0x88       { return 11; }
    if static_cast::<u64>(static_cast::<u16>(wide)) != 0x7788     { return 12; }
    if static_cast::<u64>(static_cast::<u32>(wide)) != 0x55667788 { return 13; }

    // ---- check 14: narrowing to zero ----------------------------------------
    // A value whose low bits are all zero narrows to 0. Worth checking on its
    // own because 0 is the one result that looks like "nothing happened" rather
    // than like a truncation, and is therefore the hardest to notice.
    var round: u64 = static_cast::<u64>(1) << 32;
    if static_cast::<u64>(static_cast::<u32>(round)) != 0 { return 14; }

    // ---- check 15: round trip through the narrow type -----------------------
    // A value that FITS the narrow type must survive the round trip unchanged.
    // If this fails while 11-13 pass, narrowing is corrupting values it had no
    // need to touch, which is worse than a truncation rule being wrong.
    var fits: u64 = 200;
    if static_cast::<u64>(static_cast::<u8>(fits)) != 200 { return 15; }

    return 0;
}
