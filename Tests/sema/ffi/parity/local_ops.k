// rule: member operator (`a + a`, binding `const V&`), free operators found
// only by ADL through a `vm::V` operand (`2 * a`, `a == b`), member unary.
// A LOCAL header, so this case needs no system include paths: it is the one
// that proves the oracle works on ffi today.

ffi "c++" import "../operators.h"

fn use_ops() {
    var a = make_v()
    var b = a + a
    var c = 2 * a
    var n = -a
    var e = a == b
}

// --- lit wiring -----------------------------------------------------------
// PARITY CASE. The .cpp beside this file is the ORACLE: the assertion is that
// kairo and clang reach the same verdict. See Tests/parity_check.py.
//
// RUN: %parity %s
// REQUIRES: clang
