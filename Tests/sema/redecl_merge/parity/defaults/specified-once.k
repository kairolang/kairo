// ported: clang/test/SemaCXX/default1.cpp
// rule: a default may be SPECIFIED once per parameter per scope. The
// first declaration having none is fine; the error is on the second
// specification, not on disagreement.
// EXPECT-ERROR: 7: default-arg-redefinition

fn f(i32)
fn f(x: i32 = 0)
fn f(x: i32 = 17)

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
