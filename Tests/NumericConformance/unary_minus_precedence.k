/// --- The Kairo Project --- Tests/NumericConformance/unary_minus_precedence.k --- ///
///
/// Prefix `-` applies to its operand, not to the enclosing binary expression.
/// `-10 + 5` is `(-10) + 5`, which is -5. A compiler that folds it as
/// `-(10 + 5)` gets -15, silently, and propagates that into runtime code.
///
/// This is not an exotic corner. The idiomatic way to spell a signed minimum is
/// `-MAX - 1`, which under the bug becomes `-(MAX - 1)` -- off by two and still
/// negative, so it survives every sanity check anyone would think to write.
///
/// STAGE 0 TODAY: FAILS at check 1. Stage 0 has exactly this bug. Do not "fix"
/// this file; the arithmetic here is not a language decision, it is arithmetic.
///
/// IF STAGE 1 FAILS ANY CHECK HERE: every negative constant in the compiler is
/// suspect, including the ones in Compiler/Support/Limits.k, which works around
/// this bug by parenthesising (`(-MAX) - 1`) and by preferring direct literals.
///

fn main() -> i32 {
    // ---- check 1: addition, where the two readings disagree in magnitude ----
    // (-10) + 5 == -5.  -(10 + 5) == -15.
    // Expected -5. A result of -15 is this bug and nothing else; no other
    // plausible defect produces exactly that number.
    if (-10 + 5) != -5 { return 1; }

    // ---- check 2: subtraction, the asymmetric case -------------------------
    // (-10) - 5 == -15.  -(10 - 5) == -5.
    // Deliberately the mirror of check 1: the two operations swap the right and
    // wrong answers. A compiler that fails 1 and 2 with the values crossed over
    // has the precedence inverted; one that fails only one of them has
    // something stranger wrong and the diagnosis above does not apply.
    if (-10 - 5) != -15 { return 2; }

    // ---- check 3: the spelling that matters ---------------------------------
    // This is `-MAX - 1` in miniature, the shape used to write a signed
    // minimum. Correct: -128. Under the bug: -126.
    //
    // Both are negative, both are near the right magnitude, and nothing about
    // -126 looks wrong at a glance. That is why this check exists separately
    // from check 2 even though it is the same operation.
    if (-127 - 1) != -128 { return 3; }

    // ---- check 4: parenthesising the operand must fix it --------------------
    // If check 3 fails and this passes, the workaround is confirmed available:
    // parenthesise the unary operand everywhere a signed minimum is spelled.
    // If BOTH fail, the bug is deeper than precedence and parenthesisation will
    // not save the compiler's own constants.
    if ((-127) - 1) != -128 { return 4; }

    // ---- check 5: multiplication, where the bug hides -----------------------
    // -(2 * 3) and (-2) * 3 are both -6, so multiplication cannot detect the
    // bug. Checked anyway so that a future change which breaks multiplication
    // -- a real regression that checks 1-4 would miss -- is still caught here.
    if (-2 * 3) != -6 { return 5; }

    // ---- check 6: the value must survive into a variable --------------------
    // Checks 1-5 are all in comparison position, where a compiler could in
    // principle fold differently than it does when initialising storage.
    // This confirms the wrong value is not merely a comparison artefact.
    var folded: i64 = -10 + 5;
    if folded != -5 { return 6; }

    // ---- check 7: runtime arithmetic, the control group ---------------------
    // The same computation with the negation forced at runtime. Stage 0 passes
    // this while failing check 1, which localises its bug precisely to constant
    // folding rather than to code generation for negation.
    //
    // If this fails but check 1 passes, the diagnosis inverts: folding is fine
    // and the code generator's negation is broken.
    var ten: i64 = 10;
    var five: i64 = 5;
    if ((0 - ten) + five) != -5 { return 7; }

    return 0;
}
