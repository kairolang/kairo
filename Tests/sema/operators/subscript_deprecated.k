// `@deprecated` on `op []` and on a conversion `op as` warns at each use.
class Old {
    var n: i32 = 0
    @deprecated("index through get")
    fn op [](self, i: usize) -> i32 {
        return self.n
    }

    @deprecated("convert by hand")
    fn op as(self) -> i32 {
        return self.n
    }
}

fn use(o: Old) -> i32 {
    var a = o[1]
    var b = o as i32
    return a + b
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: subscript_deprecated.k:16:14: warning [SC146W]: {{.*}} is deprecated: index through get
// CHECK: subscript_deprecated.k:17:13: warning [SC146W]: {{.*}} is deprecated: convert by hand
