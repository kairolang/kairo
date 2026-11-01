// Function hints apply only to functions, `@hot_path` and `@cold_path`
// contradict each other, and a method is never `const fn`: `const self`
// is how a method promises not to change its object.

@hot_path @cold_path
fn both() { }

@hot_path
struct NotAFn { var x: i32 }

class C {
    const fn m(self) -> i32 { return 1 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: fn_attr_misuse.k:5:{{[0-9]+}}: error [SC001E]:
// CHECK-DAG: fn_attr_misuse.k:8:{{[0-9]+}}: error [SC001E]: '@hot_path' applies only to a function
// CHECK-DAG: fn_attr_misuse.k:12:{{[0-9]+}}: error [SC001E]: a method cannot be const
