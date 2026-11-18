// ported: clang/test/CXX/dcl.decl/dcl.meaning/dcl.fct.default/p2.cpp
// rule: defaults ACCUMULATE across a chain, one specification each. The
// third decl may give i a default only because j and k already have one.
// Pairwise comparison in _merge_cell must reach decl 1 from decl 5, not
// only the immediately previous link.
// EXPECT-ERROR: 12: default-arg-redefinition

fn f0(i: i32, j: i32, k: i32 = 3)
fn f0(i: i32, j: i32, k: i32)
fn f0(i: i32, j: i32 = 2, k: i32)
fn f0(i: i32 = 1, j: i32, k: i32)
fn f0(i: i32, j: i32, k: i32)
fn f0(i: i32 = 1, j: i32, k: i32)

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
