// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// `as` between two spellings of one C++ type is the
// identity (redundant, so only the SC031W lint), not SC027E.
// CHECK-NOT: error
// CHECK: warning [SC031W]: redundant cast
// CHECK-NOT: error
ffi "c++" import "foreign_alias_identity.h"

fn main() -> i32 {
    var j = to_json("x", 1)
    var c = api::completion().create(j as api::detail::Json)
    return c.dump()
}
