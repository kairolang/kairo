/// --- The Kairo Project --- Tests/NumericConformance/integer_32bit_band.k --- ///
///
/// The single most important numeric test in this directory.
///
/// An integer literal that needs exactly 32 bits -- anything in [2^31, 2^32) --
/// must be a positive value. If it is typed as *signed* 32-bit instead of being
/// promoted, `0xFFFFFFFF` becomes -1, and the damage is not a wrong constant.
/// It is dead code: `if v > 0xFFFFFFFF` against a 64-bit `v` becomes
/// `v > 0xFFFFFFFFFFFFFFFF` and can never fire, so every bounds check written
/// against that constant silently stops existing, and every `v & 0xFFFFFFFF`
/// mask silently returns `v` unchanged instead of its low 32 bits.
///
/// STAGE 0 TODAY: FAILS at check 3, the very first literal inside the band.
/// Stage 0 has exactly this bug. Do not "fix" this file to make stage 0 pass --
/// the file is right, stage 0 is wrong. Checks 1-2 pass there, which is what
/// makes the failure specific rather than "large numbers are broken": the band
/// has a floor and a ceiling and stage 0 is only wrong between them.
///
/// Because main returns on the FIRST failure, stage 0 stops at 3 and never
/// reaches 5-9. Those are not known-good under stage 0; they are unreached.
///
/// IF STAGE 1 FAILS ANY CHECK HERE, STOP. Do not proceed to other tests. A
/// compiler with this bug cannot be trusted to bounds-check anything, and every
/// mask it computes is suspect.
///

fn main() -> i32 {
    // Built from small literals, because the whole point of this file is that
    // the literal forms cannot be trusted yet. `1 << 32` needs 33 bits, so it
    // is outside the suspect band and is safe to spell this way.
    var two32:   u64 = static_cast::<u64>(1) << 32;   // 4294967296
    var two31:   u64 = static_cast::<u64>(1) << 31;   // 2147483648
    var u32_max: u64 = two32 - 1;                     // 4294967295

    // ---- checks 1-2: below the band, the control group ----------------------
    // 2^31 - 1 is the largest value that fits a SIGNED 32-bit integer, so no
    // compiler mistypes it. If either of these fails, the problem is not the
    // band; something much more basic is wrong with shifts or subtraction, and
    // nothing else in this directory will be interpretable.
    var below: u64 = two31 - 1;                       // 2147483647
    if below != 2147483647 { return 1; }
    if (below > 0) != true { return 2; }

    // ---- check 3: the literal at the bottom edge of the band ----------------
    // 2147483648 is 2^31: the first value that does NOT fit a signed 32-bit
    // integer. Read as signed it is -2147483648. This is the first literal that
    // can go wrong, so it is checked against a shift rather than against itself.
    if 2147483648 != two31 { return 3; }

    // ---- check 4: the literal must be POSITIVE ------------------------------
    // Separate from check 3 on purpose. A compiler that stores the right bit
    // pattern but the wrong signedness passes check 3 (the patterns match) and
    // fails here. That distinction is the whole bug: the bits are fine, the
    // interpretation is not.
    if (2147483648 > 0) != true { return 4; }

    // ---- check 5: the top of the band, the constant that actually shipped ----
    // 4294967295 == 0xFFFFFFFF. THIS IS THE ONE. Stage 0 evaluates it as -1.
    //
    // A failure here means: search the compiler sources for `0xFFFFFFFF` and
    // treat every hit in a 64-bit context as dead code until proven otherwise.
    // See Compiler/Support/Limits.k, which exists solely because of this, and
    // use `U32_MAX` from it rather than writing the literal.
    if 4294967295 != u32_max { return 5; }
    if 0xFFFFFFFF != u32_max { return 6; }

    // ---- checks 7-8: the two shapes the bug actually destroys ---------------
    // Not redundant with check 5. Check 5 says the constant has the right
    // value; these say the constant still behaves correctly in the two
    // expressions the compiler is full of. A comparison and a mask are how the
    // bug reaches production, and both fail silently rather than loudly.
    var big:   u64 = 5000000000;                      // > 2^32, must exceed it
    var small: u64 = 100;                             // < 2^32, must not
    if (big > 0xFFFFFFFF) != true    { return 7; }
    if (small > 0xFFFFFFFF) != false { return 8; }

    // The mask. `0x1122334455667788 & 0xFFFFFFFF` is the low half, 0x55667788.
    // Under the bug the mask is all-ones and this returns the input unchanged,
    // which is why the expected value below is written out rather than derived.
    var wide: u64 = 0x1122334455667788;
    if (wide & 0xFFFFFFFF) != 0x55667788 { return 9; }

    // ---- check 10: above the band, the other control group ------------------
    // 2^32 needs 33 bits and is therefore outside the band. Stage 0 gets this
    // right. If checks 5-9 fail but this passes, the diagnosis is exactly "the
    // 32-bit band"; if this fails too, the problem is wider and this file's
    // framing is wrong -- go read integer_width_boundaries.k first.
    if 4294967296 != two32 { return 10; }
    if (4294967296 > 4294967295) != true { return 11; }

    return 0;
}
