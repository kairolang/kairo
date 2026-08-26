/// --- The Kairo Project --- Tests/NumericConformance/float_basics.k --- ///
///
/// IEEE-754 behaviour that the compiler must not quietly "improve". Floats
/// invite a different class of mistake from integers: not a wrong bit pattern
/// but an over-eager algebraic identity, applied at compile time, that is valid
/// over the reals and false over floating point.
///
/// The identities checked here are the ones an optimiser is most tempted by.
/// `x + 0.0 == x` is false for negative zero. `(a + b) + c == a + (b + c)` is
/// false in general because addition is not associative. A compiler that folds
/// either of those has enabled fast-math semantics somewhere, and the resulting
/// numbers stay plausible while ceasing to be reproducible.
///
/// DECISION: strict IEEE-754 is assumed, i.e. no fast-math, no reassociation,
/// no assumption that NaN cannot occur. If Kairo ever adopts fast-math as a
/// default rather than an opt-in flag, checks 5-8 will fail and that is the
/// signal to stop and make it an explicit, documented, opt-in choice.
///
/// STAGE 0 TODAY: FAILS at check 13. Under stage 0 a narrowing cast to f32 is a
/// no-op -- 0.1 round-trips through f32 unchanged, which is impossible for a
/// real 24-bit mantissa -- so f32 there is silently f64. Checks 1-12 pass. Do
/// not relax check 13 to make stage 0 pass; the check is right.
///

fn main() -> i32 {
    // ---- checks 1-3: exact values ------------------------------------------
    // Values with exact binary representations, so equality comparison is
    // legitimate here in a way it would not be for, say, 0.1. If these fail,
    // the problem is literal parsing rather than arithmetic; nothing further in
    // this file will be interpretable.
    var half:    f64 = 0.5;
    var quarter: f64 = 0.25;
    var one:     f64 = 1.0;
    if (half + half) != one          { return 1; }
    if (half * half) != quarter      { return 2; }
    if (one / quarter) != 4.0        { return 3; }

    // ---- check 4: the inexact case, checked by tolerance --------------------
    // 0.1 has no exact binary representation, so 0.1 + 0.2 != 0.3 exactly, and
    // asserting otherwise would be asserting that the compiler is WRONG.
    // Checked within a tolerance instead. A compiler that passes this by
    // computing exactly 0.3 has replaced the arithmetic with decimal or
    // extended-precision evaluation, which is its own bug.
    var sum: f64 = 0.1 + 0.2;
    var diff: f64 = sum - 0.3;
    if diff < 0.0 { diff = 0.0 - diff; }
    if (diff < 0.000000001) != true { return 4; }

    // ---- checks 5-6: negative zero -----------------------------------------
    // -0.0 and 0.0 compare EQUAL under IEEE-754 but are distinct values with
    // different bit patterns. The two facts together are what make `x + 0.0`
    // unsafe to fold away: for x = -0.0 the sum is +0.0, a different value.
    //
    // If check 5 fails, the comparison is comparing bits instead of following
    // IEEE. If check 6 fails, the two zeroes have been collapsed into one.
    var pos_zero: f64 = 0.0;
    var neg_zero: f64 = -0.0;
    if (pos_zero == neg_zero) != true { return 5; }
    // 1/+0 is +infinity and 1/-0 is -infinity, which is how the two zeroes are
    // told apart without reaching for bit inspection.
    var pos_inf: f64 = one / pos_zero;
    var neg_inf: f64 = one / neg_zero;
    if (pos_inf == neg_inf) != false { return 6; }
    if (pos_inf > 0.0) != true       { return 7; }
    if (neg_inf < 0.0) != true       { return 8; }

    // ---- checks 9-10: NaN ---------------------------------------------------
    // NaN is not equal to itself. This is the single most commonly broken float
    // property, because `x == x` is exactly the kind of thing a compiler folds
    // to true without thinking, and doing so silently removes every NaN check
    // anyone has written.
    var nan: f64 = pos_inf - pos_inf;
    if (nan == nan) != false { return 9; }
    if (nan != nan) != true  { return 10; }

    // ---- check 11: associativity must NOT hold ------------------------------
    // Chosen so the two groupings genuinely differ in f64. The gap between 1.0
    // and the next representable double is about 2.22e-16, so a lone 1e-16 is
    // below half that gap and rounds away entirely, while two of them added
    // together first clear the threshold and survive:
    //
    //   (1.0 + 1e-16) + 1e-16  ==  1.0                  each addend vanishes
    //   1.0 + (1e-16 + 1e-16)  ==  1.0000000000000002   combined, they do not
    //
    // The magnitudes matter. An earlier draft used 1e18 and 1.0, where BOTH
    // groupings round back to 1e18 -- the check passed vacuously and asserted
    // nothing. If this check is ever edited, verify the two groupings still
    // differ before trusting a pass.
    //
    // If this fails, the compiler is reassociating floating-point addition and
    // results are no longer reproducible across optimisation levels.
    //
    // Spelled `1.0e-16`, with the fractional part, NOT `1e-16`. Stage 0 reads
    // an exponent-form literal that has no `.` as zero, which would make this
    // check compare 1.0 against 1.0 and pass while testing nothing. That bug
    // has its own file, float_exponent_notation.k; the spelling here is chosen
    // so this check tests associativity rather than re-testing that.
    var big:  f64 = 1.0;
    var tiny: f64 = 1.0e-16;
    var left:  f64 = (big + tiny) + tiny;
    var right: f64 = big + (tiny + tiny);
    if (left == right) != false { return 11; }

    // ---- checks 12-13: width must not change the value ----------------------
    // A value exactly representable in f32 must survive a round trip through
    // it. A value that is not must NOT come back unchanged -- otherwise the
    // narrowing is not happening at all and f32 is silently f64.
    //
    // Check 13 is the load-bearing half. 0.1 has no exact representation at
    // either width, and f32's 24-bit mantissa is coarser than f64's 53, so the
    // round trip MUST perturb it -- the f32 nearest to 0.1 is about
    // 0.100000001490116, measurably larger. Coming back exactly equal proves no
    // narrowing occurred. This is what stage 0 fails.
    //
    // If check 13 fails, every f32 in the compiled program is really an f64:
    // twice the memory, different results, and any code relying on f32 rounding
    // behaviour is quietly getting f64 rounding instead.
    var exact: f64 = 0.5;
    if static_cast::<f64>(static_cast::<f32>(exact)) != 0.5 { return 12; }
    var inexact: f64 = 0.1;
    if (static_cast::<f64>(static_cast::<f32>(inexact)) == 0.1) != false { return 13; }

    return 0;
}
