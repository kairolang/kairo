// rule: a primitive type may head an expression when `::` follows it, and
// the pass that can see which form it is diagnoses it.
//
//   - Parser: admits `f128::MAX`; a bare `f128` in value position is still
//     "expected expression".
//   - N: a primitive names no decl, so it is left unbound ON PURPOSE -- not
//     the I003E "survived name resolution unbound" internal error.
//   - An associated constant (`f128::MAX`) is a literal before N runs
//     (Sema/Expand/PrimitiveLimitDesugar.k), so it types as an f128.
//   - ChainBinding: any other member (`f128::NOPE`) is R024E, the
//     type-position error in expression position.
//
// The call form, `u32(1)`, is primitive_call.k: R024E belongs to the T stage,
// which stops the pipeline, so CallTyping never runs in a file that has it.

fn limit() -> f128 { return f128::MAX }
fn member() -> f128 { return f128::NOPE }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: primitive_head.k:16:
// DIAG: primitive_head.k:17:{{[0-9]+}}: error [R024E]: 'f128' is a primitive type; it has no member 'NOPE'
//
// Neither the parse error nor the internal error anywhere in the output.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// NONE-NOT: S052E
// NONE-NOT: I003E