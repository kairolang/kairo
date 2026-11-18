// ported: clang/test/SemaCXX/out-of-line-def-mismatch.cpp
// rule: an out-of-line definition must match an in-class SIGNATURE, not
// merely a name. N(a) only checked the name, so this is the case R(b)
// exists to catch.
// EXPECT-ERROR: 7: out-of-line-signature-mismatch

class C {
    fn bump()
}

fn C::bump(x: i32) { }

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
