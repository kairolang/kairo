// Where the panic set must be written (PANIC.md §2.2): a `fn` type and an
// interface requirement (no body to infer from), a virtual method of a
// base (a contract for every override), and a closure (a readability
// rule). A bare `panic` there is an error; where there is a body, the edit
// writes the set it was inferred to be -- or removes `panic` when nothing
// in the body panics, since `panic()` is not a set.

struct E { var code: i32 }
struct F { var code: i32 }

fn thrower() panic(E) -> i32 { panic E { code: 1 } }

fn takes(f: fn() panic -> i32, g: fn() panic(E) -> i32) -> i32 { return 0 }

interface Loader {
    fn load(self) panic -> i32
    fn load_declared(self) panic(E, F) -> i32
}

class Base {
    var n: i32
    virtual fn step(self) panic -> i32 { return thrower() }
    virtual fn pure_step(self) panic -> i32
    virtual fn declared(self) panic(E) -> i32 { return thrower() }
    // Not virtual: an ordinary method may infer.
    fn plain(self) panic -> i32 { return thrower() }
}

fn closures() -> i32 {
    var a = fn () panic -> i32 { return thrower() }
    var b = fn () panic -> i32 { return 1 }
    var c = fn () panic(E) -> i32 { return thrower() }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: required_sets.k:13:18: error [SC001E]: the panic set of a 'fn' type must be declared: 'fn(T) panic(E) -> U'
// CHECK-NEXT: required_sets.k:13:18: note [SC001N]: there is no body to infer it from
// CHECK: required_sets.k:16:19: error [SC001E]: the panic set of interface requirement 'load' must be declared: it is the contract every conformer is held to
// CHECK-NEXT: required_sets.k:16:19: note [SC001N]: there is no body to infer it from
// CHECK: required_sets.k:22:27: error [SC001E]: the panic set of virtual method 'step' must be declared: it is the contract every override is held to
// CHECK-NEXT: fix-it:"{{.*}}required_sets.k":{22:27-22:32}:"panic(E)"
// CHECK: required_sets.k:23:32: error [SC001E]: the panic set of virtual method 'pure_step' must be declared: it is the contract every override is held to
// CHECK-NEXT: required_sets.k:23:32: note [SC001N]: there is no body to infer it from
// CHECK: required_sets.k:30:19: error [SC001E]: a closure's panic set must be declared: 'fn () panic(E) -> T'
// CHECK-NEXT: fix-it:"{{.*}}required_sets.k":{30:19-30:24}:"panic(E)"
// CHECK: required_sets.k:31:19: error [SC001E]: a closure's panic set must be declared: 'fn () panic(E) -> T'
// CHECK-NEXT: fix-it:"{{.*}}required_sets.k":{31:19-31:24}:""
