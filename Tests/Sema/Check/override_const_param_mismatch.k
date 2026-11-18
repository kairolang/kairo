// A written `const s: string` is a different parameter from the base's by-value
// `s: string` (a const reference, not a copy), so the override overrides
// nothing: SC150E names the base method it was compared with.

class Base {
    virtual fn f(self, s: string) -> i32 { return 1 }
}

class D derives Base {
    override fn f(self, const s: string) -> i32 { return 7 }
}

fn main() -> i32 {
    var d = D()
    return d.f("x") - 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: override_const_param_mismatch.k:10:5: error [SC150E]: 'f' is marked 'override' but overrides nothing
