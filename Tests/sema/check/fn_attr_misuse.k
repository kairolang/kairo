// Function hints apply only to functions, `@hot_path` and `@cold_path`
// contradict each other, and a method is never a const function: `const self`
// is how a method promises not to change its object.

@hot_path @cold_path
fn both() { }

@hot_path
struct NotAFn { var x: i32 }

class C {
    fn m(self) const -> i32 { return 1 }
    static fn s() const -> i32 { return 2 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: fn_attr_misuse.k:5:{{[0-9]+}}: error [SC147E]:
// CHECK-DAG: fn_attr_misuse.k:8:{{[0-9]+}}: error [SC143E]: '@hot_path' applies only to a function
// CHECK-DAG: fn_attr_misuse.k:12:{{[0-9]+}}: error [S047E]: a const method is spelled 'fn name(const self)'
// CHECK-DAG: fn_attr_misuse.k:13:{{[0-9]+}}: error [S047E]: a method cannot be const
