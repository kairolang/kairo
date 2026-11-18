// rule: a declared return type against an omitted (void) one is a
// mismatch. The case that goes silently unreported if the null-canonical
// early-return in _check_return_agrees fires too eagerly.
// EXPECT-ERROR: 5: fn-return-type-differs

fn k(i32) -> i32
fn k(x: i32) { }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it.
//
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict (both accept, or both reject).
// Message text is deliberately NOT compared -- see Tests/parity_check.py.
// On failure clang is right by definition, unless the difference is a
// deliberate Kairo rule -- in which case the case belongs in kairo-only/.
//
// RUN: %parity %s
// REQUIRES: clang
