// What panic does not support yet (SC116E):
// - a `<T: type>` body (MONO.md D1, the C++-checked regime behind
//   -fduck-generics): a call through T is never resolved, so its body has no
//   set to close at the definition. A `panic` function under such a
//   parameter, and any panicking site in its body, caught or not -- in a
//   closure inside it too. (A bounded or opaque generic is P10's: its set is
//   computed at the definition, Tests/Sema/Panic/generics.k.)
// - a generic closure, and a `fn` type whose set names a generic parameter
//   (deduction never reads a `fn` type's effect);
// - a panic result held in a variable (§1.1): a bare `catch e` binding is
//   `Panic<void, L...>` (§3.6); re-panicking it is fine, `var c = e` not;
// - generators and `async` (§2.7): the error surfaces at the resume site,
//   which needs the coroutine frame. A `panic` generator or `async`
//   function, and any panicking site in either body.

struct E { var code: i32 }

fn thrower() panic -> i32 { panic E { code: 1 } }

fn <T: type> duck_panic(x: T) panic -> T { return x }

fn <T: type> duck_body(x: T) -> i32 {
    var a = try thrower() catch => 0
    var f = fn () panic(E) -> i32 { return thrower() }
    return a + thrower()
}

class <T: type> DuckBox {
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
// RUN: { %kairo %s --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: gates.k:20:31: error [SC116E]: a 'panic' function under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:23:17: error [SC116E]: a call that may panic inside a function under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:24:44: error [SC116E]: a call that may panic inside a closure under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:25:16: error [SC116E]: a call that may panic inside a function under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:30:18: error [SC116E]: a 'panic' function under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:31:36: error [SC116E]: a call that may panic inside a function under a '<T: type>' parameter (C++-checked generics) is not yet supported
// CHECK: gates.k:34:10: error [SC116E]: a 'panic' generator is not yet supported
// CHECK: gates.k:37:11: error [SC116E]: a call that may panic inside a generator is not yet supported
// CHECK: gates.k:40:16: error [SC116E]: an 'async' 'panic' function is not yet supported
// CHECK: gates.k:42:40: error [SC116E]: a 'fn' type's panic set that depends on a generic parameter is not yet supported
// CHECK: gates.k:49:44: error [SC116E]: a stored panic result is not yet supported
