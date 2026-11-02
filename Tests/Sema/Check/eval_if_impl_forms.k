// The forms of a type test a function-body `eval if` cannot decide per
// instantiation (P234): `derives` has no concept yet, and an `impl` test
// must name a generic parameter -- the one subject C++ substitutes.

interface Shape {
    static fn sides() -> i32
}
class Square impl Shape {
    static fn sides() -> i32 { return 4 }
}
class Base { }

fn <T> f() -> i32 {
    eval if T derives Base { return 1 } else { return 2 }
}

fn g() -> i32 {
    eval if Square impl Shape { return 1 } else { return 2 }
}

fn main() -> i32 { return f<Square>() + g() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: eval_if_impl_forms.k:14:13: error [SC001E]: 'derives' in a function-body 'eval if' is not supported yet; test an interface with 'impl'
// CHECK: eval_if_impl_forms.k:18:13: error [SC001E]: an 'impl' test in a function-body 'eval if' must name a generic parameter of the function or its class
// CHECK-NOT: evaluable at compile time
