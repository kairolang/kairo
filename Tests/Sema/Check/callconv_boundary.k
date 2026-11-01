// A calling convention cannot cross the C/C++ boundary (SC136E): GCC has
// no spelling for it. A function that is not `priv` is in the module's C++
// header, and an `ffi` declaration is C or C++ by definition. `priv` and a
// function local to another stay in their TU.

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
// CHECK-DAG: callconv_boundary.k:7:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary: GCC cannot call it
// CHECK-DAG: callconv_boundary.k:10:{{[0-9]+}}: error [SC136E]: '@preserve_all' cannot cross the C/C++ boundary: GCC cannot call it
// CHECK-DAG: callconv_boundary.k:14:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary
// CHECK-DAG: callconv_boundary.k:19:{{[0-9]+}}: error [SC136E]: '@preserve_most' cannot cross the C/C++ boundary
// CHECK-NOT: callconv_boundary.k:{{2[3-9]|3[0-9]}}:{{.*}}error
