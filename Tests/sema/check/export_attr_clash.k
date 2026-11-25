// Two exports of one name, or an export named like an `ffi "c"` function the
// same file defines, would define one C symbol twice. An `ffi "c"` function
// exported under its own name is that symbol already, which is no clash.

@export("render")
fn render_table(n: i32) -> i32 { return n }

@export("render")
fn render_list(n: i32) -> i32 { return n + 1 }

ffi "c" fn kairo_step(n: i32) -> i32 { return n + 2 }

@export("kairo_step")
fn step(n: i32) -> i32 { return n + 3 }

@export("kairo_self")
ffi "c" fn kairo_self(n: i32) -> i32 { return n + 4 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: export_attr_clash.k:8:1: error [SC370E]: 'render' is already the C name of 'render_table'; two functions cannot define one C symbol
// CHECK-NEXT: export_attr_clash.k:5:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'render' is defined here
// CHECK: export_attr_clash.k:13:1: error [SC370E]: 'kairo_step' is already the C name of 'kairo_step'; two functions cannot define one C symbol
// CHECK-NEXT: export_attr_clash.k:11:{{[0-9]+}}: note [{{[A-Z0-9]+}}]: 'kairo_step' is defined here
// CHECK-NOT: export_attr_clash.k:16:{{.*}}error
