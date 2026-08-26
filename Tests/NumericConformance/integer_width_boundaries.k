/// --- The Kairo Project --- Tests/NumericConformance/integer_width_boundaries.k --- ///
///
/// Every power-of-two boundary where a value stops fitting one width and needs
/// the next, checked from both sides. These are the only inputs that separate
/// "evaluates integers correctly" from "evaluates small integers correctly": a
/// compiler that narrows one step too early is exactly right everywhere except
/// within one ulp of a boundary, and there it is catastrophically wrong.
///
/// Each width is checked three times, and the three are not redundant:
///   - the largest value that fits          (must be exact)
///   - that value's sign                    (must be positive; catches the
///                                           signed/unsigned mistyping that
///                                           preserves the bit pattern)
///   - the first value that does not fit    (must promote, not wrap to 0)
///
/// The wrap-to-zero case is the one worth understanding. If 256 narrows into 8
/// bits it becomes 0, and 0 is a legal, unremarkable number that every later
/// pass will happily agree was always there. Nothing downstream can recover it.
///
/// STAGE 0 TODAY: FAILS at check 9, the step across the SIGNED 32-bit boundary
/// -- the band opens at 2^31, not at 2^32. That is the same bug isolated in
/// integer_32bit_band.k; read that file first, it explains this failure.
/// Checks 1-8 pass, so stage 0 is correct at 8 and 16 bits. Because main
/// returns on the first failure, checks 10-17 are unreached under stage 0, not
/// known-good there.
///
/// SCOPE: 64 bits and below. Literals at or above 2^64 are in
/// integer_128bit_range.k, which stage 0 cannot compile at all.
///

fn main() -> i32 {
    // Reference values built by shifting, never by spelling the literal, so
    // that a literal-evaluation bug cannot corrupt the thing it is checked
    // against. 1 << N is unambiguous at every N used here.
    var one: u64 = 1;

    // ---- checks 1-3: the 8-bit boundary -------------------------------------
    if 255 != ((one << 8) - 1)  { return 1; }
    if (255 > 0) != true        { return 2; }
    // 256 must be 256, not 0. A zero here means an 8-bit accumulator.
    if 256 != (one << 8)        { return 3; }

    // ---- checks 4-6: the 16-bit boundary ------------------------------------
    if 65535 != ((one << 16) - 1) { return 4; }
    if (65535 > 0) != true        { return 5; }
    if 65536 != (one << 16)       { return 6; }

    // ---- checks 7-9: the signed 32-bit boundary -----------------------------
    // 2^31 - 1 is the largest value fitting a SIGNED 32-bit integer. Nothing
    // mistypes it, which is what makes it a useful control immediately before
    // the boundary that everything mistypes.
    if 2147483647 != ((one << 31) - 1) { return 7; }
    if (2147483647 > 0) != true        { return 8; }
    // The step across the signed boundary. See integer_32bit_band.k.
    if 2147483648 != (one << 31)       { return 9; }

    // ---- checks 10-12: the unsigned 32-bit boundary -------------------------
    // Still inside the band stage 0 gets wrong. 4294967295 is 0xFFFFFFFF; read
    // as signed 32-bit it is -1, so check 10 fails and check 11 fails harder --
    // a positive constant testing as negative.
    if 4294967295 != ((one << 32) - 1) { return 10; }
    if (4294967295 > 0) != true        { return 11; }
    if 4294967296 != (one << 32)       { return 12; }

    // ---- checks 13-15: the signed 64-bit boundary ---------------------------
    // The same hazard as checks 9-11, one width up. A compiler that fixed the
    // 32-bit band by special-casing it, rather than by promoting properly, will
    // pass 10-12 and fail here -- which is precisely why this is checked.
    if 9223372036854775807 != ((one << 63) - 1) { return 13; }
    if (9223372036854775807 > 0) != true        { return 14; }
    if 9223372036854775808 != (one << 63)       { return 15; }

    // ---- checks 16-17: the top of the 64-bit range --------------------------
    // 2^64 - 1, all ones. Cannot be built as `(1 << 64) - 1` because a 64-bit
    // shift by 64 is undefined in most machine models, so it is derived by
    // doubling the top bit instead. If check 16 fails, suspect the derivation
    // before the literal: verify `(one << 63)` is right via check 15 first.
    var top_bit: u64 = one << 63;
    if 18446744073709551615 != (top_bit + (top_bit - 1)) { return 16; }
    if (18446744073709551615 > 0) != true                { return 17; }

    return 0;
}
