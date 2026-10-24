// RUN: %kairo %s --type-check-only -I %S/Inputs/a/include -I %S/Inputs/b/include -I %S/Inputs/c/include 2>&1 | %FileCheck %s --allow-empty
//
// Bugs/Triage F20: header dirs collided as module roots. Every C/C++ project
// has several `-I .../include` dirs (`kairo x.k -I build/llvm/include
// -I Lib/llvm-runtimes/llvm/include -I Lib/llvm-runtimes/lld/include`); when
// each -I was a root NAMED by its folder, all three were `include` and the
// build died with R018E before parsing anything. A search dir has no name,
// so there is nothing to collide: the run exits 0 (no `|| true` above) and a
// file in any of them imports by its path under that dir.

import alpha
import beta

fn sum() -> i32 {
    return alpha::alpha() + beta::beta()
}

// CHECK-NOT: R018E
// CHECK-NOT: error
