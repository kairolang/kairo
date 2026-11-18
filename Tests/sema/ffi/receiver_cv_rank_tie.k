// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
//
// `amb() const` and `amb() volatile` each bind a plain object, and neither
// qualification is a subset of the other, so C++ calls it ambiguous; the
// receiver cv tie-break (receiver_cv_rank.k) must leave it so.

ffi "c++" import "receiver_cv_rank.h"

fn main() -> i32 {
    var c: Cell
    return c.amb()
}

// CHECK: receiver_cv_rank_tie.k:11:12: error [SC064E]: call to 'amb' is ambiguous
