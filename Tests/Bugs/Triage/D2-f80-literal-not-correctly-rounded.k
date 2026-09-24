//  build: kairo D2-f80-literal-not-correctly-rounded.k --print-sema --type-check-only --dump-type-info --print-tokens
// version: kairo-0.1.1+dev.20260907
// note: --dump-type-info is not yet implemented in this build - also this code
// WILL fail to compile on non x86_64 targets because f80 is not supported on
// those platforms, but the bug is present on all platforms regardless of whether
// f80 is supported or not.
//
// ("-- type info: ... (not yet implemented) --"), so it adds nothing here.
// --print-tokens, however, DOES demonstrate the bug directly, without
// needing codegen/bit-level inspection:
//
//   [11] floating point '3.14159' @ [27, 49)
//         `- float f64 = 3.14159  base=10
//
// The literal 3.14159265358979323846 is evaluated and truncated to
// f64 precision (3.14159, 6 decimal digits) at the TOKEN level before
// sema sees the `x: f80` type annotation, before compute_f80 runs.
// This means the f80 declared type on `x` cannot possibly recover the
// lost precision: the source digits beyond f64 precision are discarded
// at lex time, not merely mis-rounded during exponent scaling.
//
// ### Expected behavior
// The lexer/literal evaluator must preserve the literal in full
// arbitrary-precision decimal (or at minimum f80-sufficient precision)
// form, tagged with its expected/contextual type, and defer rounding to
// the target-type-aware evaluator (APFloat convertFromString semantics,
// or an Eisel-Lemire / Clinger fast-path) not evaluate to a hardcoded
// f64 intermediate before the type is known.
//
// ### Additional context
// Source: FloatData::compute_f80 (Lexer/Immediate literal evaluation).
// Per code inspection, compute_f80 itself is also not correctly rounded:
// it applies the exponent by repeated *= 10.0 / /= 10.0 (up to 4932
// times) and builds the fraction as num / 10^k in f80 arithmetic,
// accumulating error rather than producing the IEEE 754-2019
// correctly-rounded result the compliance page promises. But per the
// --print-tokens dump above, this is a SECONDARY bug: the primary bug is
// that the literal is already collapsed to f64 precision before
// compute_f80 (or any f80-aware path) would even run. Fix the token-level
// truncation first, then verify compute_f80's rounding independently
// don't assume fixing the multiply loop alone will resolve this, since
// the upstream precision loss makes that fix insufficient on its own.
//
// Not independently verified whether compute_f80 is invoked at all for
// this input given the f64 token trace FloatData's evaluation call
// path for `var x: f80 = <literal>` to confirm whether it's (a) never
// reached, (b) reached but fed the already-truncated f64 value, or
// (c) reached with full precision and truncating separately. These are
// three different bugs with different fixes.

class Foo {}

fn f() {
    var x: f80 = 3.14159265358979323846

    var y: Foo = match x {
        case 3.14159265358979323846 { 129 } // expected to match, but does not
        default { 102 } // taken instead, because x was truncated to f64 precision
    }
}