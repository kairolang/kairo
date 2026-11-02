// An identifier in an imported `pub macro`'s body is spelled in the
// DEFINING file's immediate table. It reached the importing file carrying
// that file's index, and every lookup read the index against the importing
// file's table, where it is some other name: `callee!()(4)` called `main`
// ("expects 0 argument(s), 1 given"), and `twice!(n)` the same way.
// ASTContext::get_ident_imm now re-keys such an identifier by spelling.
// The prelude's `crash!` (Lib/builtin) depends on this: its body names
// `crash_with`.
//
// Also: `plus!(n)`, a body `helper_fn(x) + helper_fn(x)`, was SC066E
// "operator '+' is not defined on primitives" (the `+` reached Sema still
// macro-wrapped), and `twice!(5)`, a literal argument substituted into the
// foreign body, was SC073E "integer literal has no immediate data".
//
// Inputs/macro_ident_import: lib.k declares the macros, app.k uses them.
// app.k (not main.k: the main.k-module ticket) returns 3 + 4 + 7 + 6 + 5.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_ident_import && { %kairo app.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/macro_ident_import && %kairo app.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 25
