// rule: a NON-CONST LVALUE into `(T&, const T&)` binds `T&`
// ([over.ics.rank]/3.2.6: the less cv-qualified reference wins). Both accept
// it, so only the pick shows the rule: `h(T&)` returns double, the SEMA
// check pins `r : f64`, and the oracle static_asserts the same.

ffi "c++" import "../ref_overload.h"

fn use_nonconst() {
    var t = T()
    var r = h(&t)
}

// SEMA:      -- inferred decls --
// SEMA:      r : f64

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
