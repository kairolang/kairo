/// --- The Kairo Project --- Tests/NumericConformance/integer_literal_losslessness.k --- ///
///
/// REQUIRES: literals-above-64-bit
///
/// A literal must never lose value information at the lexer, however large it
/// is. There is no "too large" to diagnose here: Kairo has fixed widths from 8
/// to 512 bits AND arbitrary-precision bigints, so whether a given literal fits
/// depends entirely on the type it is eventually used at. 2^200 is an error at
/// i64, fine at i256, and always fine at a bigint. The lexer sees the digits
/// long before any of that is decided.
///
/// So the lexer's contract is not judgement, it is CAPTURE: escalate 64 -> 128
/// -> BigInt as needed and hand sema something it can range-check later. Range
/// enforcement belongs to whoever assigns the type, and cannot happen earlier
/// without guessing.
///
/// WHAT THIS FILE IS FOR: making sure the escalation actually happens. A value
/// that silently wraps instead of escalating is unrecoverable -- by the time
/// anything downstream could object, the digits are gone.
///
/// HISTORY. This file previously asserted that a 2^128 literal must FAIL TO
/// COMPILE, which was the right test for a 64-bit-max language and the wrong
/// one for this language. It also happened to pass for the wrong reason: the
/// escalation was broken, so 2^128 became 0 and 2^128+1 became 1, both of them
/// ordinary small integers that every later pass would agree were always
/// written there. The cause was an off-by-one in the 128-bit overflow test in
/// Compiler/Lexer/Immediate.k -- overflow was checked before the multiply and
/// ignored the addend, so at `val == max_safe` the final digit wrapped without
/// being noticed. Fixed; these checks are what hold it fixed.
///
/// STAGE 0 TODAY: CANNOT COMPILE THIS FILE, and that is expected, not a
/// failure. Stage 0 rejects any literal at or above 2^64 outright ("integer
/// literal is too large to be represented in any integer type"), which is
/// correct for stage 0's own 64-bit world and wrong for Kairo's. run.sh reports
/// this file as `skip` there. It is a stage-1 test.
///
/// STAGE 1's LEXER IS ALREADY CORRECT on every literal below, verified via
/// --print-tokens: each escalates to a BigInt with the right inferred width
/// (2^128 -> i256, 2^255 -> i256, 2^256 -> i512, 2^512 -> i1024). This file
/// exists to keep that true once stage 1 can run what it lexes.
///
/// DECISION: none. The value of a numeral is not a design choice. Which TYPE it
/// gets is, but that question lives in sema, not here.
///

fn main() -> i32 {
    // ---- checks 1-2: the last value that fits 128 bits ----------------------
    // 2^128 - 1, both limbs saturated. The control group: everything below this
    // was already correct, so a failure here means something much more basic
    // broke than the boundary handling this file is about.
    var max128: u128 = 340282366920938463463374607431768211455;
    var built:  u128 = 0;
    var one:    u128 = 1;
    var top:    u128 = one << 127;
    built = top + (top - 1);
    if max128 != built { return 1; }
    if (max128 + 1) != 0 { return 2; }

    // ---- checks 3-4: THE BOUNDARY. 2^128 exactly ----------------------------
    // This is the literal that used to become 0.
    //
    // It cannot be held in a u128, so it is checked by arithmetic that brings
    // it back into range: dividing by 2 gives exactly 2^127, which is the top
    // bit and nothing else. If the literal wrapped to 0, this is 0 and the
    // check fails; if it escalated correctly, it is `top`.
    //
    // A failure here means the 64 -> 128 -> BigInt escalation is not firing at
    // the boundary. Look at Int128::mul_add_128 in Compiler/Lexer/Immediate.k
    // and check that its overflow test accounts for the ADDEND and not just
    // the multiply -- that is the exact bug this file was written for.
    var two128_half: u128 = 340282366920938463463374607431768211456 / 2;
    if two128_half != top { return 3; }

    // ---- check 4: 2^128 + 1, which used to become 1 -------------------------
    // Subtracting 2^128 - 1 leaves exactly 2. Chosen because the wrong answer
    // under the old bug was 1, and 1 - (2^128 - 1) underflows to something
    // enormous rather than to 2, so the two outcomes are far apart.
    var two128_plus1_minus_max: u128 =
        340282366920938463463374607431768211457 - 340282366920938463463374607431768211455;
    if two128_plus1_minus_max != 2 { return 4; }

    // ---- check 5: a multiple of the boundary --------------------------------
    // 2^128 * 10. Under the old bug this also became 0, because the wrap
    // cascaded through the remaining digits. Divided by 10 it must be 2^128,
    // and halving that gives 2^127 again.
    var two128_times10_over20: u128 = 3402823669209384634633746074317682114560 / 20;
    if two128_times10_over20 != top { return 5; }

    // ---- checks 6-7: the width the literal is given -------------------------
    // Not just the value: the inferred width must be wide enough to hold it.
    // A literal that escalates correctly but is then typed too narrow is the
    // same data loss one pass later.
    //
    // 2^200 needs 201 bits, so it must land in something at least 256 wide, and
    // must survive a round trip through that type unchanged.
    var one256: u256 = 1;
    var wide200: u256 = 1606938044258990275541962092341162602522202993782792835301376;
    var rebuilt200: u256 = one256 << 200;
    if wide200 != rebuilt200 { return 6; }

    // 2^400 needs 401 bits: past 256, so this only works if the escalation is
    // genuinely unbounded rather than capped at the next width up.
    var one512: u512 = 1;
    var wide400: u512 =
        2582249878086908589655919172003011874329705792829223512830659356540647622016841194629645353280137831435903171972747493376;
    var rebuilt400: u512 = one512 << 400;
    if wide400 != rebuilt400 { return 7; }

    // ---- check 8: no silent truncation to a small number --------------------
    // Stated separately and bluntly. Every failure mode this file guards
    // against produces a SMALL number -- 0, 1, or a single digit -- because the
    // wrap always lands on the final digit. So the cheapest possible assertion
    // is also a meaningful one: a huge literal must not be small.
    //
    // If checks 3-7 somehow pass and this fails, the value is being lost
    // somewhere other than the escalation, and the comments above will not lead
    // anywhere useful.
    var huge: u512 = 340282366920938463463374607431768211456;
    if (huge > 1000000) != true { return 8; }

    return 0;
}
