// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// An extension operator whose declared return type is wrong. Both halves are
// checked against the DECLARATION: the body's `bool` does not convert to the
// declared `cont<f32>`, and a use sees `cont<f32>`, not the body's `bool`,
// so the `if` rejects it. The extension method beside it is unaffected.

ffi "c++" import "../traits_typedef.h"

extend cont<i32> {
    fn doubled(self) -> u64 { return self.size() * 2 }
    fn op ==(self, other: cont<i32>) -> cont<f32> { return self.size() == other.size() }
}

fn use_ext() -> u64 {
    var a: cont<i32>
    var b: cont<i32>
    a.push(1)
    if a == b { return 0 }
    return a.doubled()
}

// DIAG:     operator_return.k:12:{{[0-9]+}}: error [SC001E]: cannot convert 'bool' to 'cont<f32, alloc>'
// DIAG:     operator_return.k:19:8: error [SC001E]: the 'if' condition must be 'bool', not 'cont<f32, alloc>'
// DIAG-NOT: error
