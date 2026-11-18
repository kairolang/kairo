// witness/assoc_modules/main.k -- exit 62
// The interface and its bounded bodies (graph), the conformers (roads) and
// the instantiating module (this one) are three TUs: the associated type
// is resolved in graph through the bound, the conformer's alias is found
// across TUs for the instance fact (`pick(Map())` is a City here), and the
// specialization declaring `Node` is written where the instance is homed.
import graph
import roads::*
fn main() -> i32 {
    var c: City = graph::pick(Map())
    var l: i64 = graph::pick(Road())
    return graph::heaviest(Road()) + graph::heaviest(Map()) + c.id + (l as i32)   // 21 + 14 + 7 + 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 62
