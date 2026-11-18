// A function named after a primitive type (`fn f16(...)`) is one error at
// the name, and its parameters still resolve in the body. It must not parse
// as a parameterless closure, which makes every use of a parameter R020E
// "undeclared" and the function itself vanished.

class Base { var k: i32 = 1 }

fn f16(c: *Base) -> i32 { return c->k }
fn u8(c: i32) -> i32 { return c + 1 }
fn g2(c: *Base) -> i32 { return c->k }

fn main() -> i32 {
    var b = Base()
    return g2(&b)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: fn_primitive_name.k:8:4: error [S047E]: 'f16' names a primitive type and cannot name a function
// DIAG-NOT: R020E
// DIAG: fn_primitive_name.k:9:4: error [S047E]: 'u8' names a primitive type and cannot name a function
// DIAG-NOT: {{error|warning}}
