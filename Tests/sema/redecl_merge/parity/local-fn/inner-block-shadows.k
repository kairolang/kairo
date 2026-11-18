// rule: an inner block SHADOWS rather than colliding, same as a `var`.
// Visible in --print-sema as a shadow note on the declare row; not a
// diagnostic, matching clang, which only says so under -Wshadow.
// EXPECT-CLEAN
// EXPECT-SEMA: inner helper shadows fn helper @ 2:5 in an enclosing frame

fn outer() {
    fn helper() { }
    if true {
        fn helper() { }
    }
}

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
