// `var x: const T` and `fn f(x: const T)` mean exactly `const x: T`: a const
// on the TYPE at a binding site is a const binding. Legal, but the keyword no
// longer says what the binding is, so it is a readability warning whose fix
// moves the const onto the binding. Saying it twice -- `const x: const T` --
// is a hard error on the second const. A const UNDER a pointer is not at the
// top of the type and is neither.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s

fn params(x: const i32, const y: const i32, z: *const i32, const w: i32) { }

fn locals() {
    var a: const i32 = 1
    const b: const i32 = 2
    var p: const *i32 = &null
    const q: *const i32 = &null
}

// CHECK:      const_binding_type.k:10:14: warning [S001W]: 'const' on the type of a parameter is hard to read; declare the parameter 'const' instead
// CHECK-NEXT: const_binding_type.k:10:34: error [S001E]: the parameter is already 'const'; a second 'const' on its type is not allowed
// CHECK-NEXT: const_binding_type.k:13:12: warning [S001W]: 'const' on the type of a 'var' binding is hard to read; declare the binding 'const' instead
// CHECK-NEXT: const_binding_type.k:14:14: error [S001E]: the binding is already 'const'; a second 'const' on its type is not allowed
// CHECK-NEXT: const_binding_type.k:15:12: warning [S001W]: 'const' on the type of a 'var' binding is hard to read; declare the binding 'const' instead
// CHECK-NOT:  {{warning|error}}
