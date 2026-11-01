// The calling convention is part of the declaration: a forward declaration
// and its definition, or an in-class declaration and its out-of-line
// definition, must agree (R039E, the convention named in the note). A
// convention alone does not make a second overload.

@preserve_most
priv fn fwd(n: usize) -> usize

priv fn fwd(n: usize) -> usize { return n }

priv fn plain(n: usize) -> usize

@preserve_all
priv fn plain(n: usize) -> usize { return n }

@preserve_none
priv fn agree(n: usize) -> usize

@preserve_none
priv fn agree(n: usize) -> usize { return n }

priv class Box {
    @preserve_most
    fn get(self) -> i32
}

fn Box::get(self) -> i32 { return 1 }

fn main() -> i32 { return (fwd(0) + plain(0) + agree(0)) as i32 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: callconv_redecl_mismatch.k:9:{{[0-9]+}}: error [R039E]: 'fwd' redeclared with the default calling convention
// CHECK-DAG: callconv_redecl_mismatch.k:7:{{[0-9]+}}: note [R039N]: previously declared here with '@preserve_most'
// CHECK-DAG: callconv_redecl_mismatch.k:14:{{[0-9]+}}: error [R039E]: 'plain' redeclared with '@preserve_all'
// CHECK-DAG: callconv_redecl_mismatch.k:11:{{[0-9]+}}: note [R039N]: previously declared here with the default calling convention
// CHECK-DAG: callconv_redecl_mismatch.k:27:{{[0-9]+}}: error [R039E]: 'get' redeclared with the default calling convention
// CHECK-DAG: callconv_redecl_mismatch.k:24:{{[0-9]+}}: note [R039N]: previously declared here with '@preserve_most'
// CHECK-NOT: callconv_redecl_mismatch.k:{{1[6-9]|20}}:{{.*}}error
