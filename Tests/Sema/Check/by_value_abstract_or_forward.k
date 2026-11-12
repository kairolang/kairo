// A definition's by-value parameter or return, and a field, can hold only
// what can be an object: not an abstract class (SC249E, as
// constructing one is) and not a record only ever forward-declared
// (SC227E). Both passed Sema and failed in clang (CL001E "parameter type
// 'A' is an abstract class", "variable has incomplete type"). A `const` or
// `@inout` parameter is a reference, and a declaration with no body may
// name either, as in C++; a pointer is always fine.

class A { virtual fn f(self) -> i32 }
class B derives A { override fn f(self) -> i32 { return 3 } }
struct Opaque

fn take(a: A) -> i32 { return 1 }
fn take_c(const a: A) -> i32 { return 1 }
fn take_i(@inout a: A) -> i32 { return 1 }
fn take_p(a: *A) -> i32 { return a->f() }
fn decl_only(a: A) -> i32
fn mk() -> A { crash!() }
fn use_it(o: Opaque) -> i32 { return 1 }
fn use_p(o: *Opaque) -> i32 { return 1 }

class H {
    pub var a: A
    pub var b: B
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK: by_value_abstract_or_forward.k:13:9: error [SC249E]: parameter 'a' holds an object of abstract class 'A' by value; hold a pointer to it instead
// CHECK: by_value_abstract_or_forward.k:9:11: note [SC249N]: 'f' is pure virtual and nothing overrides it, so 'A' is abstract
// CHECK: by_value_abstract_or_forward.k:18:12: error [SC249E]: the return value of 'mk' holds an object of abstract class 'A' by value
// CHECK: by_value_abstract_or_forward.k:19:11: error [SC227E]: parameter 'o' holds 'Opaque' by value, but 'Opaque' is only forward-declared, so its size is unknown
// CHECK: by_value_abstract_or_forward.k:11:1: note [SC227N]: 'Opaque' is forward-declared here and never defined
// CHECK: by_value_abstract_or_forward.k:23:16: error [SC249E]: field 'a' holds an object of abstract class 'A' by value
