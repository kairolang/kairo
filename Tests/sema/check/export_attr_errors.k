// `@export(name)` stands on a free function defined in Kairo whose
// signature is a C function's, and names it with one string literal that is a
// C identifier. Every other use is an error.

class Widget {
    @export("widget_size")
    static fn size() -> i32 { return 1 }
}

@export("not_a_fn")
var counter: i32 = 0

@export(render)
fn bare_name() -> i32 { return 0 }

@export("render-table")
fn dashed() -> i32 { return 0 }

@export("__kairo_x")
fn reserved() -> i32 { return 0 }

@export("ident")
fn <T> generic(x: T) -> T { return x }

@export("takes_string")
fn takes_string(s: string) -> i32 { return 0 }

@export("returns_slice")
fn returns_slice(p: unsafe *i32) -> [i32] { return [1] }

@export("inout_param")
fn inout_param(@inout x: i32) { x = 1 }

@export("nullable_param")
fn nullable_param(x: i32?) -> i32 { return 0 }

@export("two")
@export("names")
fn two_names(x: f64) -> f64 { return x }

@export("ok_fn")
fn ok_fn(a: i8, b: u64, c: f32, d: bool, e: unsafe *u8, f: usize) -> i32 { return 0 }

@export("main_too")
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: export_attr_errors.k:6:5: error [SC143E]: '@export' applies only to a free function; to export a method, export a free function that calls it
// CHECK-DAG: export_attr_errors.k:10:1: error [SC143E]: '@export' applies only to a free function
// CHECK-DAG: export_attr_errors.k:13:9: error [SC144E]: '@export' takes one string literal, the C name: '@export("render")'
// CHECK-DAG: export_attr_errors.k:16:9: error [SC144E]: 'render-table' is not a C identifier; '@export' needs letters, digits and '_', not starting with a digit
// CHECK-DAG: fix-it:"{{.*}}export_attr_errors.k":{16:9-16:23}:"\"render_table\""
// CHECK-DAG: export_attr_errors.k:19:9: error [SC144E]: '__kairo_x' begins with '__kairo_', which is reserved for the compiler
// CHECK-DAG: export_attr_errors.k:22:1: error [SC369E]: generic function 'generic' cannot be exported: a C name names one function, and a generic function is one per instance
// CHECK-DAG: export_attr_errors.k:26:{{[0-9]+}}: error [SC369E]: parameter 's' of 'takes_string' has type 'string', which is not a C type
// CHECK-DAG: export_attr_errors.k:29:{{[0-9]+}}: error [SC369E]: 'returns_slice' returns '[i32]', which is not a C type
// CHECK-DAG: export_attr_errors.k:32:{{[0-9]+}}: error [SC369E]: parameter 'x' of 'inout_param' is passed @inout, as a C++ reference, which C has no type for; take a pointer instead
// CHECK-DAG: export_attr_errors.k:35:{{[0-9]+}}: error [SC369E]: parameter 'x' of 'nullable_param' has type 'i32?', which is not a C type
// CHECK-DAG: export_attr_errors.k:38:1: error [SC144E]: 'two_names' is already exported; a function has one '@export'
// CHECK-DAG: export_attr_errors.k:44:1: error [SC143E]: '@export' does not apply to the program's entry point
// CHECK-NOT: export_attr_errors.k:41:{{.*}}error
