// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// G107: `make_unique<Gen>(inc_ref)` where the argument's class is only
// forward-declared in the call's header set. The quiet attempt at clang's
// deduction treated EVERY failure as undecided, including the plain `enable_if`
// removal of libc++'s deleted bounded-array overload, so it tied with the
// non-array one (SC064E). Only a hard error is undecided.
// CHECK-NOT: error

ffi "c++" import "inc.h"
ffi "c++" import "memory"

fn mk() -> cxx::std::unique_ptr<mi::Gen> {
    return cxx::std::make_unique<mi::Gen>(mi::get_inc(), 3, false)
}
