// An `@inout` argument must be written with `&`: a plain pointee `*p` and a
// plain value are rejected, while the marked `&*p` and `&v` forms are
// accepted.

class Inv { pub var n: i32; }

fn bump(@inout inv: Inv, k: i32) -> i32 { inv.n += k; return inv.n; }

fn main() -> i32 {
    var v = Inv { n: 1 };
    var p: unsafe *Inv = unsafe &v;
    var a = bump(&*p, 2);
    var b = bump(&v, 3);
    var c = bump(*p, 4);
    var d = bump(v, 5);
    return a + b;
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: inout_deref_ptr_arg_reject.k:14:18: error [SC097E]: argument to '@inout' parameter 'inv' must be marked with '&'
// CHECK: fix-it:{{.*}}:{14:18-14:18}:"&"
// CHECK: inout_deref_ptr_arg_reject.k:15:18: error [SC097E]: argument to '@inout' parameter 'inv' must be marked with '&'
