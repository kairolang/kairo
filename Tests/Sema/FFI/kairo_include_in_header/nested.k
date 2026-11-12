ffi "c++" import "outer.h"

// Reached through a second header: outer.h includes inner.h (twice,
// and inner.h has no guard), inner.h includes a .k that is in no
// compilation. One error, at inner.h's line, with no "is the importing
// file" sentence, and both headers' declarations import.
fn main() -> i32 {
    return outer_api(inner_api(1))
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      inner.h:1:10: error [R070E]: a C or C++ header imported from Kairo cannot include the Kairo source file 'stray.k'{{$}}
// CHECK-NEXT: nested.k:1:18: note [I900N]: 'outer.h' is imported here, and its includes reach 'inner.h'
// CHECK-NEXT: note [R070N]: the header has to declare what it uses itself
// CHECK-NOT:  {{error|warning}} [
// A full build stops at the same one error: the codegen PCH and the C++
// TUs, which have no hook, are never reached.
// RUN: { %kairo %s -o %t 2>&1 || true; } | %FileCheck %s --check-prefix=FULL
// FULL:      inner.h:1:10: error [R070E]:
// FULL-NEXT: nested.k:1:18: note [I900N]:
// FULL-NEXT: note [R070N]:
// FULL-NOT:  {{error|warning}} [
