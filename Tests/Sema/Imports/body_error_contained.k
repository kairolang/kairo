// An error in a method BODY (here N's R020E) poisons that body, not the
// module's declarations. N's errors do not stop the TU before T (which would leave no
// signature in it resolved and fail every importer's call
// "parameter type is unresolved", as `std::print` in
// Command::print_help, or SC063E on `cmd->define<FlagKind::X>(...)` in
// FlagRegistry.k). T runs, and the TU stops after it.

// RUN: cd %S/Inputs/body_error_contained && { %kairo %s -I . --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["

// CHECK: M.k:10:9: error [R020E]: use of undeclared identifier 'nowhere'

import M::*;

fn f(c: unsafe *C) -> i32 {
    var p = c->define<FlagKind::Bool>("a", false);
    return c->h(1) + free_alloc<i32>(2);
}
