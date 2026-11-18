// A pointer compared with a non-pointer operand is still an error: the
// builtin pointer comparison does not make `p != "x"` or `p == 3.5` valid.
// The pointer-to-pointer comparisons beside them are accepted.

ffi "c++" import "pointer_compare_no_operator.h"

fn f() -> bool {
    var p = pc::find(1)
    var q = pc::find(2)
    if p != &null { return true }
    if p != "x" { return true }
    return p == 3.5
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='I003E'
// CHECK: pointer_compare_no_operator_reject.k:11:8: error [SC063E]: no matching overload for call to 'op !='
// CHECK: pointer_compare_no_operator_reject.k:12:12: error [SC066E]: no operator '==' for operands 'unsafe *Node' and 'f64'
