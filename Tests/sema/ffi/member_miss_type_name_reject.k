// A field-style access that misses on an imported C++ receiver reports
// R025E with the type's spelling, while the member the type does have
// (`size`) still resolves; only the missing name is an error.
ffi "c++" import "member_miss_type_name.h"

fn main() -> i32 {
    var t: thing
    var n = t.size()
    var m = t.count
    return n
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error [' --implicit-check-not='this type'
// CHECK: member_miss_type_name_reject.k:[[#]]:[[#]]: error [R025E]: no member named 'count' in 'basic<int>'
