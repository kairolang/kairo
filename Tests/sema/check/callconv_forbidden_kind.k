// A calling convention cannot be set on a function that code Kairo does
// not write calls (SC134E): constructors, destructors, operators, `main`,
// generators, `async` functions, closures and `eval fn`s.

priv class Buf {
    var n: i32

    @preserve_most
    fn Buf(self) { self.n = 0 }

    @preserve_most
    fn op finally(self) { }

    @preserve_all
    fn op + (self, other: Buf) -> Buf { return Buf() }
}

@preserve_most
priv fn gen() -> yield i32 { yield 1 }

@preserve_most
priv fn later() async -> i32 { return 1 }

@preserve_none
priv eval fn twice(x: i32) -> i32 { return x * 2 }

@preserve_most
fn main() -> i32 {
    var f = @preserve_most fn (x: i32) -> i32 { return x }
    return f(0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --target=x86_64-linux-gnu 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: callconv_forbidden_kind.k:9:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on a constructor
// CHECK-DAG: callconv_forbidden_kind.k:12:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on a destructor
// CHECK-DAG: callconv_forbidden_kind.k:15:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on an operator
// CHECK-DAG: callconv_forbidden_kind.k:19:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on a generator
// CHECK-DAG: callconv_forbidden_kind.k:22:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on an 'async' function
// CHECK-DAG: callconv_forbidden_kind.k:25:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on an 'eval fn'
// CHECK-DAG: callconv_forbidden_kind.k:28:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on 'main'
// CHECK-DAG: callconv_forbidden_kind.k:29:{{[0-9]+}}: error [SC134E]: a calling convention cannot be set on a closure
// CHECK-NOT: SC116E
