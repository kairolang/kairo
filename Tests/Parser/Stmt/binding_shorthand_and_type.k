// A loop or destructuring binder that writes a shorthand and a type is
// refused as the same declaration with `var` is: `*x: T` states the
// pointer twice (the fix-it drops the `*`), and `x?: T` is written
// `x: T?` (the fix-it moves the `?`).

fn main() -> i32 {
    var xs = [1, 2, 3]
    for *p: *i32 in xs { }
    for unsafe *q: unsafe *i32 in xs { }
    for y?: i32 in xs { }
    var t = (1, 2)
    var (*a: *i32, b) = t
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: binding_shorthand_and_type.k:8:9: error [S058E]: '*p' states that the binding is a pointer, but the binding also annotates its type; drop the '*'
// CHECK-NEXT: fix-it:{{.*}}:{8:9-8:10}:""
// CHECK: binding_shorthand_and_type.k:9:9: error [S058E]: 'unsafe *q' states that the binding is a pointer
// CHECK-NEXT: fix-it:{{.*}}:{9:9-9:17}:""
// CHECK: binding_shorthand_and_type.k:10:10: error [S058E]: 'y?' infers a nullable type, but the binding also annotates one; write the '?' on the type
// CHECK-NEXT: fix-it:{{.*}}:{10:10-10:11}:""
// CHECK-NEXT: fix-it:{{.*}}:{10:16-10:16}:"?"
// CHECK: binding_shorthand_and_type.k:12:10: error [S058E]: '*a' states that the binding is a pointer
