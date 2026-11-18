// rule: top-level const on a parameter's TYPE is not part of the signature
// ([dcl.fct]/5) -- `const *i32` is a const pointer, and f(*i32) / f(const
// *i32) are one function. A const UNDER the top stays: g(*i32) and
// g(*const i32) are two overloads.
// EXPECT-ERROR: 8: fn-redefinition

fn f(x: *i32) { }
fn f(x: const *i32) { }

fn g(x: *i32) { }
fn g(x: *const i32) { }

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it.
//
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict (both accept, or both reject).
// Message text is deliberately NOT compared -- see Tests/parity_check.py.
// The DIAG run pins WHICH pair rejects: the verdict alone cannot tell the
// f redefinition from a wrongly merged g.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// REQUIRES: clang
//
// DIAG:      top-level-const.k:8:1: error [R029E]: redefinition of 'f'
// DIAG-NEXT: top-level-const.k:7:1: note [R029N]: previous definition of 'f' is here
// DIAG-NOT:  error
