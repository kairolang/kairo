// An identifier in an imported `pub macro`'s body is spelled in the
// DEFINING file's immediate table. It reached the importing file carrying
// that file's index, and every lookup read the index against the importing
// file's table, where it is some other name: `callee!()(4)` called `main`
// ("expects 0 argument(s), 1 given"), and `twice!(n)` the same way.
// ASTContext::get_ident_imm now re-keys such an identifier by spelling.
// The prelude's `crash!` (Lib/builtin) depends on this: its body names
// `crash_with`. Literals in a foreign body, and a literal ARGUMENT
// substituted into one (`twice!(3)`), are still the SC073E ticket.
//
// Inputs/macro_ident_import: lib.k declares the macros, main.k uses them.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_ident_import && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
