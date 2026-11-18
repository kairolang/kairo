// rule: an LVALUE argument into `(const T&, T&&)` binds `const T&` -- `T&&`
// does not accept an lvalue at all ([over.ics.ref]), so there is no tie to
// break. The oracle static_asserts the pick; the SEMA check pins it here.

ffi "c++" import "../ref_overload.h"

fn use_lvalue() {
    var t = T()
    var r = f(t)
}

// SEMA:      -- inferred decls --
// SEMA:      r : i32

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
