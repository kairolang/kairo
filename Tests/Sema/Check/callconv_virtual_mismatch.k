// Every method of one override set has the same calling convention
// (SC135E): a call through the base's slot uses the base's.

priv class Base {
    @preserve_most
    virtual fn tick(self) -> i32 { return 1 }

    virtual fn tock(self) -> i32 { return 2 }

    @preserve_all
    virtual fn same(self) -> i32 { return 3 }
}

priv class Derived derives Base {
    override fn tick(self) -> i32 { return 4 }

    @preserve_most
    override fn tock(self) -> i32 { return 5 }

    @preserve_all
    override fn same(self) -> i32 { return 6 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: callconv_virtual_mismatch.k:15:{{[0-9]+}}: error [SC135E]: 'tick' has the default calling convention, but the method it overrides has '@preserve_most'
// CHECK-DAG: callconv_virtual_mismatch.k:18:{{[0-9]+}}: error [SC135E]: 'tock' has '@preserve_most', but the method it overrides has the default calling convention
// CHECK-NOT: callconv_virtual_mismatch.k:21:{{.*}}error
