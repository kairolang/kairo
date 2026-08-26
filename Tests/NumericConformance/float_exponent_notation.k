/// --- The Kairo Project --- Tests/NumericConformance/float_exponent_notation.k --- ///
///
/// A float literal written in exponent form must have the value its notation
/// says, whether or not a fractional part is present. `1e-16`, `1.0e-16` and
/// `0.0000000000000001` are three spellings of one number and must produce one
/// value.
///
/// STAGE 0 TODAY: FAILS at check 3, and CRASHES if run past check 7.
///
/// Stage 0 mishandles exactly the literals with an exponent and NO `.`:
///
///   1.0e-16   correct        fractional part present
///   1.5e-3    correct        fractional part present
///   1e-16     evaluates to 0 <-- silent, this is check 3
///   2e-5      evaluates to 0 <-- silent
///   5e-1      evaluates to 0 <-- silent
///   1e16      SIGTRAP        <-- the produced binary dies at runtime
///   1e+16     SIGTRAP
///
/// So the same missing `.` gives a wrong answer in one direction and a crash in
/// the other. The silent-zero half is the dangerous one: `2e-5` as a tolerance
/// becomes an exact-equality test, and `5e-1` as a probability becomes never.
/// Nothing in the program looks wrong, and the crash cases at least announce
/// themselves.
///
/// A crash means the checks after it never run, so a stage-0 run of this file
/// reports check 3 and stops. That is why the positive-exponent cases are last:
/// the silent failures are worth reaching first.
///
/// STAGE 1's LEXER IS ALREADY CORRECT on every spelling below, verified against
/// --print-tokens. This file exists to keep it that way once stage 1 can run
/// what it lexes, since a lexer that is right today has no test holding it in
/// place tomorrow.
///
/// DECISION: none. The value of a numeral is not a design choice.
///

fn main() -> i32 {
    // ---- checks 1-2: the spellings that already work ------------------------
    // A fractional part is present in both. These are the control group: if
    // either fails, the problem is exponent handling in general and the
    // fraction/no-fraction split described above is the wrong diagnosis.
    var with_frac_neg: f64 = 1.0e-16;
    var with_frac_mid: f64 = 1.5e-3;
    if (with_frac_neg > 0.0) != true { return 1; }
    if with_frac_mid != 0.0015       { return 2; }

    // ---- check 3: negative exponent, no fractional part ---------------------
    // THE SILENT ONE. `1e-16` must be a small positive number, not zero.
    //
    // A failure here means every exponent-form constant without a `.` in the
    // program is zero. Grep for `e-` in float literals; each hit is a constant
    // that has silently become 0, and the code around it is doing something
    // other than what it reads as.
    var no_frac_neg: f64 = 1e-16;
    if (no_frac_neg > 0.0) != true { return 3; }

    // ---- checks 4-5: the three spellings must agree -------------------------
    // Same number, written three ways. Equality is legitimate here because all
    // three should produce the identical double, not merely close ones -- they
    // are the same value and must parse to the same bits.
    var spelled_out: f64 = 0.0000000000000001;
    if no_frac_neg != with_frac_neg { return 4; }
    if no_frac_neg != spelled_out   { return 5; }

    // ---- checks 6-7: other negative exponents, no fractional part -----------
    // 5e-1 is exactly 0.5 and representable exactly, so this is an exact
    // comparison and any inexactness is a bug rather than rounding. Included
    // because a "small values flush to zero" theory would explain check 3 but
    // not this one -- 0.5 is not small.
    var half_exp:  f64 = 5e-1;
    var small_exp: f64 = 2e-5;
    if half_exp != 0.5           { return 6; }
    if (small_exp > 0.0) != true { return 7; }

    // ---- checks 8-10: positive exponents, no fractional part ----------------
    // These CRASH the stage-0-produced binary rather than returning a wrong
    // value, so they are placed last: everything above still reports normally
    // when this file is run under a compiler with that bug.
    //
    // 1e16 is exactly representable in f64 (it is well under 2^53 scaled), so
    // the comparison against the written-out form is exact.
    var pos_exp:      f64 = 1e16;
    var pos_exp_sign: f64 = 1e+16;
    if pos_exp != 10000000000000000.0 { return 8; }
    if pos_exp_sign != pos_exp        { return 9; }

    // Round trip: dividing by the same magnitude must return exactly 1.0. This
    // catches an exponent that is off by a factor of ten, which comparing
    // against a written-out constant would also catch, but which comparing two
    // exponent forms against each other would not.
    if (pos_exp / 10000000000000000.0) != 1.0 { return 10; }

    // ---- check 11: exponent zero is the identity ----------------------------
    // `1e0` is 1.0. A parser that treats a zero exponent as "no exponent" gets
    // this right by accident; one that mis-signs or off-by-ones the exponent
    // does not.
    var exp_zero: f64 = 1e0;
    if exp_zero != 1.0 { return 11; }

    return 0;
}
