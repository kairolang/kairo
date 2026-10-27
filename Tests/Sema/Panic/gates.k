// What panic does not support yet (SC116E):
// - generics (PANIC.md §2.6): a generic body's set depends on its type
//   arguments, which only per-instance checking (M2) can see. A `panic`
//   function that is generic or inside a generic type, and any panicking
//   site in such a body, caught or not;
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

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: gates.k:14:28: error [SC116E]: a generic 'panic' function (or one inside a generic type) is not yet supported
// CHECK: gates.k:17:17: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:18:16: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:23:18: error [SC116E]: a generic 'panic' function (or one inside a generic type) is not yet supported
// CHECK: gates.k:24:36: error [SC116E]: a call that may panic inside a generic function (or one inside a generic type) is not yet supported
// CHECK: gates.k:27:10: error [SC116E]: a 'panic' generator is not yet supported
// CHECK: gates.k:30:11: error [SC116E]: a call that may panic inside a generator is not yet supported
// CHECK: gates.k:33:16: error [SC116E]: an 'async' 'panic' function is not yet supported
