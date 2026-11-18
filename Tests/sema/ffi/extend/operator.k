// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// An operator added by `extend` to an instance of an IMPORTED template: C++
// `cont` has no `==`, the extension supplies it, and `a == b` resolves to
// it with the `bool` it declares.

ffi "c++" import "../traits_typedef.h"

extend cont<i32> {
    fn op ==(self, other: cont<i32>) -> bool { return self.size() == other.size() }
}

fn use() -> u64 {
    var a: cont<i32>
    var b: cont<i32>
    if a == b { return 0 }
    return 1
}

// DIAG-NOT: error

// SEMA:      <tu>::use
// SEMA:      @ 17:8 : bool
// SEMA:      0 unknown, 0 errored
// SEMA:      0 of them dependent, 0 errored
