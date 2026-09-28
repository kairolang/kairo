// rule: a primitive type may head an expression when `::` or `(` follows it,
// and each form is diagnosed by the pass that can see which one it is.
//
//   - Parser: admits `f128::MAX` and `u32(1)`; a bare `u32` in value position
//     is still "expected expression".
//   - N: a primitive names no decl, so it is left unbound ON PURPOSE -- not
//     the I003E "survived name resolution unbound" internal error.
//   - ChainBinding: `f128::MAX` is R024E, the type-position error in
//     expression position. When primitives grow associated constants
//     (Spec/Proposals/numeric-limits.md) this line becomes a success.
//   - CallTyping: `u32(1)` is not a conversion Kairo has; `as` is.

fn member() -> f128 { return f128::MAX }
fn call() -> u32 { return u32(1) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-DAG: error [R024E]: 'f128' is a primitive type; it has no member 'MAX'
// DIAG-DAG: error [SC037E]: 'u32' is a type, not a function; convert with 'x as u32'
//
// Neither the parse error nor the internal error anywhere in the output.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// NONE-NOT: S052E
// NONE-NOT: I003E
