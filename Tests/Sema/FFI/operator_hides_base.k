// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G82: an operator member of an imported class hides the base's of the same
// operator, as any member name does ([class.member.lookup]). Operators were
// left merged, so `*it` on SpecIt tied its own `int *operator*()` with the
// base's `int &operator*()` (SC064E). A `using B::operator*;` still merges.
// CHECK-NOT: {{error|warning}}

ffi "c++" import "operator_hides_base.h"

fn deref(it: SpecIt) -> unsafe *i32 {
    return *it
}
