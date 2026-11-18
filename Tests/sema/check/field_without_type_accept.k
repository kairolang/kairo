// A field that declares its type, with or without an initializer, is
// accepted; the same shorthand `var a = 5` is only an error inside a
// record body, not in a function body.

struct S {
    var a: i32 = 5
    var b: i32
}

fn main() -> i32 {
    var x = 5
    var s = S { a: x, b: 1 }
    return s.a + s.b - 6
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="I003E" --allow-empty
