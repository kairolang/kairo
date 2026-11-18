// SC136E: GCC cannot spell a calling convention, so none may cross into C++.
// A function not `priv`, written or by default, is in the C++ header:
// with no module.k above, unmarked is `priv`, so lines 7 and 14 are fine and
// only `pub` (10) and `ffi` (19) fail. Under a module: callconv_module.k.

@preserve_most
fn public_by_default(n: usize) -> usize { return n }

@preserve_all
pub fn public_spelled(n: usize) -> usize { return n }

class Open {
    @preserve_most
    fn method(self) -> i32 { return 1 }
}

ffi "c" {
    @preserve_most
    fn c_side(n: i32) -> i32
}

@preserve_most
priv fn file_local(n: usize) -> usize { return n }

priv class Closed {
    @preserve_most
    fn method(self) -> i32 { return 1 }
}

fn main() -> i32 {
    @preserve_none
    fn local(n: usize) -> usize { return n }
    return (file_local(0) + local(0)) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: callconv_boundary.k:10:{{[0-9]+}}: error [SC136E]: '@preserve_all' cannot cross the C/C++ boundary: GCC cannot call it
// CHECK-DAG: callconv_boundary.k:19:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary
// CHECK-NOT: callconv_boundary.k:{{7|14|2[3-9]|3[0-9]}}:{{.*}}error
