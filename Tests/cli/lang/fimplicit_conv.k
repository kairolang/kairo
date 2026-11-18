// -fno-implicit-conv turns off implicit conversions in Sema, for the user's
// files only: Lib/builtin and Lib/std always compile under the default rules
// so the builtin fmt code that relies on conversions raises nothing.
// The flag still has an effect: the widening below is an error with it and
// is accepted without it. --implicit-check-not=error pins that nothing else
// (nothing from the library) is reported.

fn main() -> i32 {
    const a: i32 = 1
    const b: i64 = a
    return b as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only -fimplicit-conv
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: fimplicit_conv.k:[[@LINE-7]]:{{[0-9]+}}: error [SC028E]
