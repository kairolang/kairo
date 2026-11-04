// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// G93: `&null` passed to C++ is C++'s `nullptr`. It deduces `std::nullptr_t`
// for a forwarding-reference template parameter, is the identity match for a
// `std::nullptr_t` parameter, and still converts to any pointer parameter.
// DIAG-NOT: error

ffi "c++" import "null_pointer_literal.h"

fn main() -> i32 {
    var a = create<Target>(&null)
    var n = create<Target>(5)
    var o = OnlyNullptr(&null)
    takes_nullptr(&null)
    var b = Both(&null)
    takes_ptr(&null)
    return 0
}
