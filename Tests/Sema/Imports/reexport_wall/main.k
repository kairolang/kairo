// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// Wall 1 (IMPORTS.md 4.4) holds transitively. mid reaches deep's names
// through surface's `pub import deep::*`, but mid's own import of surface
// is private, so an importer of mid sees mid's names and nothing else.
// A re-exported target does not keep the origin of the edge it crossed in
// the SOURCE (surface's pub import), or mid would hand deep_value on as if it
// were mid's surface -- and every overlay would gain one duplicate target per
// import path, which on a large import DAG makes phase I run for minutes.

import mid::*

fn use_mid() -> i32 {
    return mid_value()
}

fn use_deep() -> i32 {
    // CHECK: main.k:[[@LINE+1]]:12: error [R020E]: use of undeclared identifier 'deep_value'
    return deep_value()
}

fn use_surface() -> i32 {
    // CHECK: main.k:[[@LINE+1]]:12: error [R020E]: use of undeclared identifier 'surface_value'
    return surface_value()
}

// CHECK-NOT: mid_value
