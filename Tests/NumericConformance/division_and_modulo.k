/// --- The Kairo Project --- Tests/NumericConformance/division_and_modulo.k --- ///
///
/// Integer division and remainder on negative operands. There are two coherent
/// conventions and both are in wide use, so the danger here is not that a
/// compiler computes nonsense -- it is that it computes the OTHER convention,
/// consistently, and looks correct until someone indexes an array with it.
///
///   truncated  (C, C++, Rust, Java, Go): -7 / 2 == -3, -7 % 2 == -1
///              quotient rounds toward zero; remainder takes the DIVIDEND's
///              sign.
///   floored    (Python, Ruby):           -7 / 2 == -4, -7 % 2 ==  1
///              quotient rounds toward negative infinity; remainder takes the
///              DIVISOR's sign.
///
/// DECISION: this file asserts TRUNCATED, because Kairo lowers to LLVM's `sdiv`
/// and `srem`, which are truncated, and because every language in Kairo's
/// lineage is truncated.
///
/// If these checks fail with the floored answers, do not patch this file first.
/// Kairo has then made -- or drifted into -- a language decision, and the thing
/// to do is write that decision down somewhere citable and then update these
/// checks to match it. If they fail with values matching NEITHER convention,
/// that is a straightforward bug.
///
/// STAGE 0 TODAY: PASSES. Stage 0 is truncated, as expected.
///

fn main() -> i32 {
    // Operands in variables, not literals, so that this file tests division and
    // not constant folding. integer_32bit_band.k and unary_minus_precedence.k
    // already cover folding; a shared failure would be ambiguous here.
    var p7: i64 = 7;
    var n7: i64 = -7;
    var p2: i64 = 2;
    var n2: i64 = -2;

    // ---- checks 1-2: the unsigned baseline ----------------------------------
    // No convention question when both operands are positive. If either of
    // these fails, division itself is broken and the sign checks below are
    // meaningless.
    if (p7 / p2) != 3 { return 1; }
    if (p7 % p2) != 1 { return 2; }

    // ---- checks 3-4: negative dividend --------------------------------------
    // Truncated: -3 and -1. Floored would give -4 and 1.
    // The remainder is the more important of the two: a -1 where 1 was expected
    // is a negative array index, and a 1 where -1 was expected is an off-by-one
    // that only appears for negative inputs.
    if (n7 / p2) != -3 { return 3; }
    if (n7 % p2) != -1 { return 4; }

    // ---- checks 5-6: negative divisor ---------------------------------------
    // Truncated: -3 and 1. Floored would give -4 and -1.
    // Note the remainder's sign follows the DIVIDEND (positive 7), which is the
    // clearest single discriminator between the two conventions.
    if (p7 / n2) != -3 { return 5; }
    if (p7 % n2) != 1  { return 6; }

    // ---- checks 7-8: both negative ------------------------------------------
    // Truncated: 3 and -1. Both conventions agree on the quotient here, so
    // check 8 is the one carrying information.
    if (n7 / n2) != 3  { return 7; }
    if (n7 % n2) != -1 { return 8; }

    // ---- check 9: the identity that must hold under either convention -------
    // (a / b) * b + (a % b) == a. This is not a convention question; it is the
    // definition of remainder, and it must hold for every pair above regardless
    // of which convention Kairo picks.
    //
    // If checks 3-8 fail but this passes, Kairo is self-consistent and has
    // simply chosen floored -- a decision to record, not a bug to fix. If this
    // fails, division and remainder disagree with each other and the compiler
    // is producing values that satisfy no convention at all. That is the
    // serious case.
    if (((n7 / p2) * p2) + (n7 % p2)) != n7 { return 9; }
    if (((p7 / n2) * n2) + (p7 % n2)) != p7 { return 10; }
    if (((n7 / n2) * n2) + (n7 % n2)) != n7 { return 11; }

    // ---- checks 12-13: unsigned division must not borrow signed behaviour ----
    // A large u64 divided by a small one. If the compiler emits `sdiv` for
    // unsigned operands, the dividend's top bit is read as a sign and the
    // quotient is wildly wrong rather than subtly wrong.
    var big: u64 = 0xFFFFFFFFFFFFFFFF;   // 2^64 - 1, top bit set
    var two: u64 = 2;
    if (big / two) != 0x7FFFFFFFFFFFFFFF { return 12; }
    if (big % two) != 1                  { return 13; }

    return 0;
}
