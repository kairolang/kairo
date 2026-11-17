// `for (k, v) in m` over a `{string: [i32]}` would copy each key and value,
// and neither `string` nor `[i32]` can be copied in this library: SC182E at
// each binder, with `const *` inserted before the name as the fix.
fn main() -> i32 {
    var m: {string: [i32]}
    m.insert("a", [1, 2])
    var n: usize = 0
    for (k, v) in m {
        n += k.size() + v.size()
    }

    return (n as i32) - 3
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: { %kairo_new %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK:      :8:10: error [SC182E]: cannot copy a value of type 'string'
// CHECK-NEXT: fix-it:"{{.*}}":{8:10-8:10}:"const *"
// CHECK:      :8:13: error [SC182E]: cannot copy a value of type '[i32]'
// CHECK-NEXT: fix-it:"{{.*}}":{8:13-8:13}:"const *"
// CHECK-NOT:  error [
