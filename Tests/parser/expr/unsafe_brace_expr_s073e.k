// `unsafe { e }` as the body of an expression-bodied function or method is the
// one-element set literal and reports S073E with a fix-it to `unsafe (e)`: it
// is neither a type mismatch against the declared result nor a set literal that
// reaches lowering.

struct P {
    var x: i32
}

fn read(p: unsafe *i32) -> i32 = unsafe { *p }

class Holder {
    var ptr: unsafe *P

    fn get(self) -> *P = unsafe { self.ptr as *P }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not='SC028E'
// CHECK: unsafe_brace_expr_s073e.k:10:41: error [S073E]: 'unsafe { e }' in an expression is a set literal; the expression form is 'unsafe (e)'
// CHECK-NEXT: fix-it:"{{.*}}":{10:41-10:42}:"("
// CHECK-NEXT: fix-it:"{{.*}}":{10:46-10:47}:")"
// CHECK: unsafe_brace_expr_s073e.k:15:33: error [S073E]
// CHECK-NEXT: fix-it:"{{.*}}":{15:33-15:34}:"("
// CHECK-NEXT: fix-it:"{{.*}}":{15:50-15:51}:")"
// A full compile stops at the diagnostic instead of reaching lowering.
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=FULL --implicit-check-not='no lowering'
// FULL: error [S073E]
// FULL: error [S073E]
