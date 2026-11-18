// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// What a qualified type path into an imported template's instance reports
// now that the `::` looks into the filled instance instead of deferring the
// whole path as dependent. Before the fill trigger in TypeResolve, all three
// lines below were silently dependent.

ffi "c++" import "traits_typedef.h"

// clang cannot instantiate `bad<i32>` (`int::st`). A failed fill is not a
// Kairo diagnostic: the path stays dependent, as it was before fills.
type failed = bad<i32>::size_type

fn missing() { var z: traits<alloc>::nope }
fn arity()   { var z: traits<alloc, alloc>::size_type }

// DIAG-NOT: dep_path_errors.k:13:
// DIAG:     dep_path_errors.k:15:{{[0-9]+}}: error [R025E]: no type named 'nope' in 'traits'
// DIAG:     dep_path_errors.k:16:{{[0-9]+}}: error [R032E]: 'traits' takes at most 1 generic argument(s), but 2 were given

// SEMA:     1 of them dependent, 2 errored
