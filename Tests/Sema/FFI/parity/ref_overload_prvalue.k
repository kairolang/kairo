// rule: a PRVALUE argument into `(const T&, T&&)` binds `T&&`
// ([over.ics.rank]/3.2.3). Both overloads accept it, so the verdict alone
// cannot see a wrong pick; each overload returns a different type, and the
// SEMA check pins the callee through `r`. The oracle static_asserts the same.

ffi "c++" import "../ref_overload.h"

fn use_prvalue() {
    var r = f(T())
}

// The prelude dumps the builtin TUs ahead of this one, each with an
// `-- inferred decls --` of its own: anchor on this file's header first.
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}ref_overload_prvalue.k =====
// SEMA:      -- inferred decls --
// SEMA-NEXT: r : f64

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// Was XFAIL until value categories reached overload resolution: `T()` is a
// prvalue, both overloads bind it at Exact, and the reference tiebreak
// (OverloadResolution::_ref_better) prefers `T&&`.
//
// RUN: %parity %s
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// REQUIRES: clang
