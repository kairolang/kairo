// A discriminant must evaluate to an integer constant, and the value must
// fit the enum's underlying type (the `derives` type, else u32). Either
// failure is SC128E, and the message says which one it is. A literal that
// does not fit is already SC075E from the literal's own typing, so it gets
// no second error, and neither does anything that only fails because an
// earlier variant did.

fn width() -> u32 { return 4; }
var counter: u32 = 3;

enum Evaluates {
    Call = width(),
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:12: error [SC128E]: an enum discriminant must be an integer constant that fits 'u32'; this one does not evaluate: a call is not evaluated at compile time
    Early = Late,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:13: error [SC128E]: an enum discriminant must be an integer constant that fits 'u32'; this one does not evaluate: 'Late' is declared below this variant, so it has no value yet
// DIAG-NEXT: enum_discriminant_err.k:[[@LINE+1]]:5: note [I900N]: 'Late' is declared here
    Late = 9,
    Myself = Myself + 1,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:14: error [SC128E]: an enum discriminant must be an integer constant that fits 'u32'; this one does not evaluate: 'Myself' is the variant being defined
    Var = counter,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:11: error [SC128E]: an enum discriminant must be an integer constant that fits 'u32'; this one does not evaluate: 'counter' is a variable; only a 'const' or 'eval' name is a constant
// DIAG-NEXT: enum_discriminant_err.k:9:1: note [I900N]: 'counter' is declared here
    Next,
    UsesFailed = Var | 1,
}

enum Fits derives u8 {
    Shifted = 1 << 8,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:15: error [SC128E]: an enum discriminant must be an integer constant that fits 'u8'; it is 256, which does not fit
// DIAG-NEXT: enum_discriminant_err.k:[[@LINE-3]]:19: note [I900N]: the underlying type is declared here
    Literal = 256,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:15: error [SC075E]: literal '256' does not fit in 'u8'
    Top = 255,
    Past,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:5: error [SC128E]: an enum discriminant must be an integer constant that fits 'u8'; 'Past' is one past 'Top', so it is 256, which does not fit
// DIAG-NEXT: enum_discriminant_err.k:[[@LINE-9]]:19: note [I900N]: the underlying type is declared here
}

enum Unsigned {
    Negative = 0 - 1,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:16: error [SC128E]: an enum discriminant must be an integer constant that fits 'u32'; it is -1, which does not fit
// DIAG-NEXT: enum_discriminant_err.k:[[@LINE-3]]:6: note [I900N]: 'Unsigned' has the default underlying type 'u32'; name a wider one with 'derives'
}

enum Signed derives i8 {
    Low  = 0 - 127 - 1,
    High = 1 << 7,
// DIAG:      enum_discriminant_err.k:[[@LINE-1]]:12: error [SC128E]: an enum discriminant must be an integer constant that fits 'i8'; it is 128, which does not fit
// DIAG-NEXT: enum_discriminant_err.k:[[@LINE-4]]:21: note [I900N]: the underlying type is declared here
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
