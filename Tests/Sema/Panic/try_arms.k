// `try` arms against the body's panic set (PANIC.md §3.1).
// - An arm whose type is not in the set never runs: a WARNING (a callee
//   removing a type from its set must not break its callers), with an
//   edit removing the arm. Statement and expression forms alike.
// - Two arms for one type: an error.
// - No subtyping: an arm catches its exact type. `catch e: Base` does not
//   catch a `Derived` panic, so against a set of {Derived} it is dead.
// - A C++ type outside the set is a C++ exception arm (§3.5): never dead,
//   and not held to the panic payload rules.
// What the arms leave goes on to the enclosing `try` or the function
// (unhandled.k).

ffi "c++" import "<stdexcept>"

struct E { var code: i32 }
struct F { var code: i32 }

class Base { var n: i32 }
class Derived derives Base { var m: i32 }

fn raises_e() panic(E) -> i32 { panic E { code: 1 } }
fn raises_derived() panic(Derived) -> i32 { panic Derived() }

fn dead_and_duplicate(x: i32) -> i32 {
    try {
        return raises_e()
    } catch e: F {
        return 0
    } catch e: E {
        return 1
    } catch e: E {
        return 2
    }
}

fn nothing_panics(x: i32) -> i32 {
    try {
        return x
    } catch e: E {
        return 1
    }
}

fn exact_types(x: i32) -> i32 {
    try {
        return raises_derived()
    } catch e: Base {
        return 1
    } catch e: Derived {
        return 2
    }
}

fn expression_form(x: i32) -> i32 {
    return try raises_e() catch e: F => 1 catch e: E => 2
}

fn cxx_exception_arm(x: i32) -> i32 {
    try {
        return raises_e()
    } catch e: cxx::std::exception {
        return 0
    } catch e: E {
        return 1
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: try_arms.k:27:7: warning [SC001W]: this arm never runs: 'F' is not in the panic set of its 'try' (this 'try' may panic only with 'E')
// CHECK-NEXT: fix-it:"{{.*}}try_arms.k":{27:7-29:6}:""
// CHECK: try_arms.k:31:7: error [SC001E]: a second 'catch' arm for 'E': the first one already catches it
// CHECK-NEXT: fix-it:"{{.*}}try_arms.k":{31:7-33:6}:""
// CHECK-NEXT: try_arms.k:29:7: note [SC001N]: the first arm is here
// CHECK: try_arms.k:39:7: warning [SC001W]: this arm never runs: 'E' is not in the panic set of its 'try' (nothing in this 'try' can panic)
// CHECK-NEXT: fix-it:"{{.*}}try_arms.k":{39:7-41:6}:""
// CHECK: try_arms.k:47:7: warning [SC001W]: this arm never runs: 'Base' is not in the panic set of its 'try' (this 'try' may panic only with 'Derived')
// CHECK-NEXT: fix-it:"{{.*}}try_arms.k":{47:7-49:6}:""
// CHECK: try_arms.k:55:27: warning [SC001W]: this arm never runs: 'F' is not in the panic set of its 'try' (this 'try' may panic only with 'E')
// CHECK-NEXT: fix-it:"{{.*}}try_arms.k":{55:27-55:42}:""
