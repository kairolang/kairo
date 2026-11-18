// rule: a primitive type may head a call, and CallTyping rejects it: `u32(1)`
// is not a conversion Kairo has; `as` is.
//
//   - Parser: admits `u32(1)`.
//   - N: the head names no decl and is left unbound ON PURPOSE (not I003E).
//   - CallTyping: SC037E, with the `as` spelling in the message.
//
// Split from primitive_head.k: that file's R024E is a T-stage error, and T
// stops the pipeline before X, so the two can never be reported by one run.

fn call() -> u32 { return u32(1) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: error [SC037E]: 'u32' is a type, not a function; convert with 'x as u32'
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NONE
// NONE-NOT: S052E
// NONE-NOT: I003E