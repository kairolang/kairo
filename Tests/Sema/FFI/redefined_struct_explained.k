// Two headers that define `struct Base` differently, imported by one
// file. Every C++ header a Kairo file imports is parsed into one
// translation unit, so this is clang's "redefinition of 'Base'", although
// neither header includes the other. The error says so, naming both
// headers, with what to do instead: import them from different Kairo
// files, or put one definition in a namespace. Nothing else changes (the
// headers still import nothing; redefined_struct_two_imports.k).

ffi "c++" import "h1.h"
ffi "c++" import "h2.h"

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/redefined_struct_two_imports %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: h2.h:1:8: error [CL001E]: redefinition of 'Base'
// CHECK-NEXT: h1.h:1:8: note [I900N]: previous definition is here
// CHECK-NEXT: note [I900N]: 'h1.h' and 'h2.h' both define 'Base': every C++ header a Kairo file imports is parsed into one translation unit, so two headers cannot both define a type of the same name; import them from different Kairo files, or put one of the definitions in a namespace
