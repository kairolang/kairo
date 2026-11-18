// rule: a local `fn` lowers to a NON-CAPTURING LAMBDA bound to a name,
// so it follows the `var` rules, not the function rules. Two in one frame
// is a redefinition -- a name binds one value, so there is no overload set
// to form and no signature comparison to make. RedeclMerge never sees
// these: local decls are excluded from symbol tables by design.
// EXPECT-ERROR: 3: local-redefinition

fn outer() {
    fn helper(x: i32) -> i32 { return 1 }
    fn helper(x: i32) -> i32 { return 2 }
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
