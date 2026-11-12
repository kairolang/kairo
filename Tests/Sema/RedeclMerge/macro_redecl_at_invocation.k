// A duplicate declared through a macro: the error belongs on the
// invocation the user wrote, with a note at the macro body that wrote the
// name. Every body token, the braces included, reads at the invocation,
// so the declaration's range is the invocation; without the note nothing
// would say which macro made the second declaration, and an error on the
// body would name one place for two invocations.

macro dup!() {
    fn f() -> i32 { return 1 }
}

macro getter!() {
    fn get(const self) -> i32 { return 1 }
}

dup!()
dup!()

class C {
    getter!()
    getter!()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: macro_redecl_at_invocation.k:17:1: error [R029E]: redefinition of 'f'
// CHECK-NEXT: macro_redecl_at_invocation.k:16:1: note [R029N]: previous definition of 'f' is here
// CHECK-NEXT: macro_redecl_at_invocation.k:9:8: note [I900N]: in expansion of macro 'dup!'
// CHECK: macro_redecl_at_invocation.k:21:5: error [R041E]: class member 'get' cannot be redeclared
// CHECK-NEXT: macro_redecl_at_invocation.k:20:5: note [R041N]: previous declaration is here
// CHECK-NEXT: macro_redecl_at_invocation.k:13:8: note [I900N]: in expansion of macro 'getter!'
