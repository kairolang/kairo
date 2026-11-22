// An attribute takes no generic arguments: `@create<T>(args)` is an error whose
// fix-it is `@create T(args)`; `@destroy<T>(p)` drops the type.

class Box {
    pub var v: i32
    fn Box(self, v: i32) { self.v = v }
    @move fn Box(self, other: Self) = default
}

fn main() -> i32 {
    var *a = @create<Box>(1)
    var *b = @create<Box>(2)
    @destroy<Box>(a)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
// CHECK: create_generic_spelling_error.k:11:21: error [S001E]: '@create' takes no generic arguments
// CHECK-NEXT: fix-it:{{.*}}{11:21-11:26}:" Box"
// CHECK: create_generic_spelling_error.k:12:21: error [S001E]: '@create' takes no generic arguments
// CHECK-NEXT: fix-it:{{.*}}{12:21-12:26}:" Box"
// CHECK: create_generic_spelling_error.k:13:13: error [S001E]: '@destroy' takes no generic arguments
// CHECK-NEXT: fix-it:{{.*}}{13:13-13:18}:""
