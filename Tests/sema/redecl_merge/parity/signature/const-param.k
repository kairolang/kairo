// ported: clang/test/SemaCXX/function-overloaded-redecl.cpp
// rule: top-level const on a parameter is NOT part of the signature, and
// an alias is transparent. Four declarations, ONE entity.
// EXPECT-ERROR: 9: fn-redefinition

type cInt = const i32

fn f(i32)
fn f(const i32)

fn f(x: i32) { }
fn f(x: cInt) { }

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
