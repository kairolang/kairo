// Two headers that both define `struct Base` differently, imported by one
// file. They are one C++ translation unit, so clang's own error is
// the one that names both definitions: "redefinition of 'Base'" at h2.h with
// a note at h1.h. A header set clang rejects imports nothing, so every name
// the file takes from it is unresolved, `f1` of h1.h included: those errors
// say why, with a note, instead of a bare R021E / R020E. With the second
// `Base` in a namespace (namespaced.k) both are distinct and usable. (Two
// IDENTICAL definitions are a clang redefinition too, one translation unit
// being C++'s rule; not pinned here, see the batch report.)

ffi "c++" import "h1.h"
ffi "c++" import "h2.h"

fn main() -> i32 {
    var b: Base
    return f1()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/redefined_struct_two_imports %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: h2.h:1:8: error [CL001E]: redefinition of 'Base'
// CHECK-NEXT: h1.h:1:8: note [I900N]: previous definition is here
// CHECK: redefined_struct_two_imports.k:15:12: error [R021E]: unknown type name 'Base'
// CHECK-NEXT: redefined_struct_two_imports.k:15:12: note [I900N]: the C++ headers this file imports did not compile (see clang's errors), so no name from them is visible
// CHECK: redefined_struct_two_imports.k:16:12: error [R020E]: use of undeclared identifier 'f1'
// CHECK-NEXT: redefined_struct_two_imports.k:16:12: note [I900N]: the C++ headers this file imports did not compile (see clang's errors), so no name from them is visible
// RUN: rm -rf %t.d
// RUN: { %kairo -I %S/Inputs/redefined_struct_two_imports %S/Inputs/redefined_struct_two_imports/namespaced.k -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=NS --allow-empty
// NS-NOT: error
// RUN: %t.exe
