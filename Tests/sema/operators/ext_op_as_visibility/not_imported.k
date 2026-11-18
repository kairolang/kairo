// The same program without the import of ext.k: the conversion does not
// exist in this file, for `as` or implicitly.

import self::types::*

fn main() -> i32 {
    var f = Feet{v: 2}
    var m = f as M
    return take(f)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: not_imported.k:8:13: error [SC027E]: no conversion from 'Feet' to 'M'
// CHECK: not_imported.k:9:12: error [SC063E]: no matching overload for call to 'take'
// CHECK: cannot convert argument of type 'Feet' to parameter 'm' of type 'M'
