// What panic does not support yet (SC116E):
// - generics (PANIC.md §2.6): a generic body's set depends on its type
//   arguments, which only per-instance checking (M2) can see. A `panic`
//   function that is generic or inside a generic type, any panicking site
//   in such a body, caught or not, and a `fn` type whose set names a
//   generic parameter;
// - a bare `catch e`'s binding used other than to re-panic it: its type,
//   whatever the `try` left, needs P1's `Panic` (PANIC.md §3.6);
// - generators and `async` (§2.7): the error surfaces at the resume site,
//   which needs the coroutine frame. A `panic` generator or `async`
//   function, and any panicking site in either body.

struct E { var code: i32 }

fn thrower() panic -> i32 { panic E { code: 1 } }

fn <T> generic_panic(x: T) panic -> T { return x }

fn <T> generic_body(x: T) -> i32 {
    var a = try thrower() catch => 0
    return a + thrower()
}

class <T> Box {
    var v: T
    fn get(self) panic -> T { return self.v }
    fn calls(self) -> i32 { return thrower() }
}

fn gen() panic -> yield i32 { yield 1 }

fn gen_body() -> yield i32 {
    yield thrower()
}

fn job() async panic -> i32 { return 1 }

fn <X> takes_generic_set(f: fn() panic(X) -> i32) -> i32 { return 0 }

fn bare_binding(x: i32) panic -> i32 {
    try { return thrower() } catch e { panic e }
}

fn bare_binding_read(x: i32) -> i32 {
    try { return thrower() } catch e { var copy = e }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: gates.k:17:28: error [SC116E]: a generic 'panic' function (or one inside a generic type) is not yet supported
// CHECK: gates.k:20:17: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:21:16: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:26:18: error [SC116E]: a generic 'panic' function (or one inside a generic type) is not yet supported
// CHECK: gates.k:27:36: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:30:10: error [SC116E]: a 'panic' generator is not yet supported
// CHECK: gates.k:33:11: error [SC116E]: a call that may panic inside a generator is not yet supported
// CHECK: gates.k:36:16: error [SC116E]: an 'async' 'panic' function is not yet supported
// CHECK: gates.k:38:40: error [SC116E]: a 'fn' type's panic set that depends on a generic parameter is not yet supported
// CHECK: gates.k:45:51: error [SC116E]: using a bare 'catch' arm's binding other than to re-panic it ('panic e') is not yet supported
