// An unmarked member is private by default outside a module
// (VisibilityFacts::default_visibility_of), so it implements a requirement
// only for an `impl` its own file declares, as a written `priv` member does
// (access_priv_witness.k). A structural conformance through it is SC162E
// from another file and in its own file alike; a `pub` member serves both.

import self::inputs::witness_unmarked_lib::*

fn <T impl HasArea> measure(t: T) -> i32 { return t.area() }

class Here {
    fn area(const self) -> i32 { return 3 }
}

fn main() -> i32 {
    return measure(Foo()) + measure(Sq()) + measure(Open()) + measure(Here())
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: witness_unmarked_cross_file.k:16:12: error [SC162E]: 'Foo' does not conform to 'HasArea': its 'area' is not public, and its file declares no 'impl HasArea'
// CHECK: witness_unmarked_cross_file.k:9:5: note [I900N]: required by this bound
// CHECK: witness_unmarked_lib.k:8:8: note [I900N]: 'area' is declared here: a private or protected member implements a requirement only for an 'impl' declared in its own file
// CHECK: witness_unmarked_cross_file.k:16:63: error [SC162E]: 'Here' does not conform to 'HasArea': its 'area' is not public, and its file declares no 'impl HasArea'
// CHECK: witness_unmarked_cross_file.k:12:8: note [I900N]: 'area' is declared here: a private or protected member implements a requirement only for an 'impl' declared in its own file
