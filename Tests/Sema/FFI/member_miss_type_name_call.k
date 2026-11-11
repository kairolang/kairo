// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// R025E on a call result. Reported by the member typer, a later
// phase than a named receiver, so it needs its own file.
// CHECK: member_miss_type_name_call.k:[[#]]:[[#]]: error [R025E]: no member named 'dump' in 'basic<long>'
// CHECK-NOT: this type
ffi "c++" import "member_miss_type_name.h"

fn main() -> i32 {
    make_other().dump()
    return 0
}
