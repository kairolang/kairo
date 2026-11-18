// rule: an imported function's arity is enforced. `point_sum(Point)` has no
// default, so a zero-argument call is rejected -- the reject half of the ffi
// oracle, so a harness that accepts everything cannot pass this directory.
// EXPECT-ERROR: 9: missing-argument

ffi "c++" import "../struct.h"

fn use_arity() -> i32 {
    return point_sum()
}

// --- lit wiring -----------------------------------------------------------
// Kept at the BOTTOM on purpose: the EXPECT-ERROR annotation above names an
// absolute LINE NUMBER in the code, so anything inserted above the code
// silently invalidates it.
//
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// REQUIRES: clang
