// A literal or constant pattern on a record tests `==`; a record with no
// `op ==` has none, and an ADT without one would compare variants only and
// ignore the payload. Both are errors at the pattern (the arm used to
// be dropped silently).

struct Q {
    var x: i32
}
eval Q1: Q = Q { x: 1 };

fn q(v: Q) -> i32 {
    match v {
        case Q1 { return 1; }
        default { return 0; }
    }
}

enum Opt { None, Some { v: i32 } }
eval S1: Opt = Opt::Some { v: 1 };

fn o(v: Opt) -> i32 {
    match v {
        case S1 { return 1; }
        default { return 0; }
    }
}

fn main() -> i32 { return q(Q { x: 1 }) + o(Opt::None); }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: match_const_pattern_no_op_eq.k:13:14: error [SC066E]: no 'op ==' on 'Q'; a record compares only through its own operator
// CHECK: match_const_pattern_no_op_eq.k:23:14: error [SC066E]: no 'op ==' on 'Opt'; a constant pattern compares through the enum's own operator, and comparing variants alone would ignore the payload
// CHECK: match_const_pattern_no_op_eq.k:18:1: note [I900N]: 'Opt' declares no 'op =='
