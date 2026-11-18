// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// R025E on an imported C++ receiver named the type 'this type'. It must
// print the type's spelling.
// CHECK: member_miss_type_name.k:[[#]]:[[#]]: error [R025E]: no member named 'dump' in 'basic<int>'
// CHECK-NOT: this type
ffi "c++" import "member_miss_type_name.h"

fn main() -> i32 {
    var t: thing
    t.dump()
    return 0
}
