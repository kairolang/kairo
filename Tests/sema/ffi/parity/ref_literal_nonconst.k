// rule: a literal is a prvalue, and a plain (non-const) `T&` binds only a
// non-const lvalue. `takes_ref(1)` has no viable candidate in either
// compiler: the verdict (both reject) is the whole assertion.

ffi "c++" import "../ref_overload.h"

fn use_literal() {
    var r = takes_ref(1)
}

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// REQUIRES: clang
