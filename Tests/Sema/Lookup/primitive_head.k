// rule: a primitive type may head an expression when `::` follows it, and
// the pass that can see which form it is diagnoses it.
//
//   - Parser: admits `f128::MAX`; a bare `f128` in value position is still
//     "expected expression".
//   - N: a primitive names no decl, so it is left unbound ON PURPOSE -- not
//     the I003E "survived name resolution unbound" internal error.
//   - ChainBinding: `f128::MAX` is R024E, the type-position error in
//     expression position. When primitives grow associated constants
//     (Spec/Proposals/numeric-limits.md) this line becomes a success.
//
// The call form, `u32(1)`, is primitive_call.k: R024E belongs to the T stage,
// which stops the pipeline, so CallTyping never runs in a file that has it.

fn member() -> f128 { return f128::MAX }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: error [R024E]: 'f128' is a primitive type; it has no member 'MAX'
//
// Neither the parse error nor the internal error anywhere in the output.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// NONE-NOT: S052E
// NONE-NOT: I003E