// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// An expression body under a written return type is typed against it, the
// same as the `return e` it abbreviates. The demand path that infers an
// unwritten return type used to answer for these as well, and it returned
// the written type without ever looking at the body: `-> u32 = true` was
// accepted, and an initializer body reached codegen untyped.
//
// Every position a function can sit in: free, extension (static and
// instance), class method, generic. A recursive call in a declared body
// must not read as the inference cycle (SC043E).

struct R { var a: u32 }

fn probe() -> u32 = true
// DIAG: expr_body_typed.k:[[@LINE-1]]:21: error [SC028E]: cannot convert 'bool' to 'u32'

extend R {
    static fn make(x: bool) -> R = R { a: x }
// DIAG: expr_body_typed.k:[[@LINE-1]]:43: error [SC028E]: cannot convert 'bool' to 'u32'
    fn flag(const self) -> bool = self.a
// DIAG: expr_body_typed.k:[[@LINE-1]]:35: error [SC028E]: cannot convert 'u32' to 'bool'
}

class C {
    var v: u32
    fn C(self) { self.v = 1 }
    fn odd(const self) -> bool = self.v % 2
// DIAG: expr_body_typed.k:[[@LINE-1]]:34: error [SC028E]: cannot convert 'u32' to 'bool'
}

fn <T: type> ident(x: T) -> T = x
fn fact(n: u32) -> u32 = n * fact(n - 1)
fn ok() -> R = R { a: fact(3) }

// `-> !` and `-> void` read the body as `return e` would: a never-returning
// call fits both, a value fits neither.
fn stop() -> ! { loop {} }
fn halt() -> ! = stop()
fn halt_bad() -> ! = 5
// DIAG: expr_body_typed.k:[[@LINE-1]]:22: error [SC028E]: cannot convert 'i32' to '!'
fn idle() -> void = stop()
fn idle_bad() -> void = fact(1)
// DIAG: expr_body_typed.k:[[@LINE-1]]:25: error [SC050E]: an expression body of type 'u32' in a function returning 'void'

// DIAG-NOT: error
