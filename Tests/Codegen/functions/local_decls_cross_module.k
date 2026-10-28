// Local declarations across modules (Inputs/local_decls_mod): lib.k has
// locals in an ordinary body, an `inline` body and a generic body; the
// latter two are compiled again in app.k's TU, whose preamble must then
// declare lib's hoisted locals and link to lib's definitions. app.k has a
// local of the same name as lib's, in its own namespace.

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/local_decls_mod && %kairo app.k --type-check-only
// RUN: cd %S/Inputs/local_decls_mod && %kairo app.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
