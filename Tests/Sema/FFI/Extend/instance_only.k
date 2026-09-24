// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// `extend cont<i32>` extends THAT instance, not the template: `cont<f32>` is
// a different registry instance and does not see the method. (Extending
// every instance is `extend <T> cont<T>` -- see generic_extend.k.)

ffi "c++" import "../traits_typedef.h"

extend cont<i32> {
    fn only_i32(self) -> u64 { return self.size() }
}

fn use() -> u64 {
    var a: cont<i32>
    var b: cont<f32>
    return a.only_i32() + b.only_i32()
}

// DIAG:     instance_only.k:16:29: error [R025E]: no member named 'only_i32' in 'cont'
// DIAG-NOT: error
