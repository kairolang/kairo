// ported: clang/test/SemaCXX/overload-decl.cpp, function-redecl-2.cpp
// rule: return type is NOT in the signature, which is exactly why a
// mismatch is a conflict rather than an overload.
// EXPECT-ERROR: 7: fn-return-type-differs

type Float = f32

fn f(i32, Float)
fn f(i32, Float) -> i32

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
