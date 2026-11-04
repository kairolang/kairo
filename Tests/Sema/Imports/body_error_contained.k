// An error in a method BODY (here N's R020E) poisons that body, not the
// module's declarations. N's errors used to stop the TU before T, so no
// signature in it was ever resolved and every importer's call failed
// "parameter type is unresolved" (self-host: `std::print` in
// Command::print_help, 363 SC063E on `cmd->define<FlagKind::X>(...)` in
// FlagRegistry.k). Now T runs, and the TU stops after it.

// RUN: cd %S/Inputs/body_error_contained && { %kairo %s -I . --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["

// CHECK: M.k:10:9: error [R020E]: use of undeclared identifier 'nowhere'

import M::*;

fn f(c: unsafe *C) -> i32 {
    var p = c->define<FlagKind::Bool>("a", false);
    return c->h(1) + free_alloc<i32>(2);
}
