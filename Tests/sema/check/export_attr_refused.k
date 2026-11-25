// The rest of the signatures `@export` refuses, and where it cannot stand: a
// generator, a function that can panic, an eval or async function, a
// parameter passed by move, a function with no body, a method.

@export("gen")
fn gen() -> yield i32 {
    yield 1
}

class Err { var c: i32 = 0 }

@export("pan")
fn pan(x: i32) panic(Err) -> i32 {
    return x
}

@export("ev")
eval fn ev(x: i32) -> i32 { return x }

@export("asy")
fn asy(x: i32) async -> i32 { return x }

@export("mv")
fn mv(@move x: i32) -> i32 { return x }

@export("decl_only")
ffi "c" fn decl_only(x: i32) -> i32

class C {
    @export("meth")
    fn m(self) -> i32 { return 1 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: export_attr_refused.k:6:{{[0-9]+}}: error [SC369E]: 'gen' returns 'Yield<i32>', which is not a C type
// CHECK-DAG: export_attr_refused.k:13:{{[0-9]+}}: error [SC369E]: 'pan' can panic, so it cannot be exported: its result carries the panic, which C cannot read
// CHECK-DAG: export_attr_refused.k:18:{{[0-9]+}}: error [SC369E]: eval function 'ev' cannot be exported: it has no code at run time
// CHECK-DAG: export_attr_refused.k:21:{{[0-9]+}}: error [SC369E]: async function 'asy' cannot be exported: it returns a task, which C cannot receive
// CHECK-DAG: export_attr_refused.k:24:{{[0-9]+}}: error [SC369E]: parameter 'x' of 'mv' is passed @move, as a C++ reference, which C has no type for; take a pointer instead
// CHECK-DAG: export_attr_refused.k:26:1: error [SC143E]: '@export' applies only to a function defined here, with a body
// CHECK-DAG: export_attr_refused.k:30:5: error [SC143E]: '@export' applies only to a free function; to export a method, export a free function that calls it
