// A macro imported BY NAME. `import lib::getter!` and the braced
// `import lib::{getter!, f}` were resolved by the preprocessor (the macro
// expanded), and name resolution then walked the same path through lib's
// symbol table, where a macro is not, and reported the import itself as
// R015E "'getter' is not declared in module 'lib'". Only `import lib::*`
// worked. The `!` spelling is the one Compiler/Spec/Lexing.md documents;
// the bare `import lib::getter` names a declaration, and now says so when
// lib has only the macro (R013E at a use, R015E otherwise, each with the
// `!` as a fix-it). A `priv` macro is still R011E. The language reference
// defines no `as` for a macro import, so one is an error naming the plain
// form (the preprocessor does not bind the alias), and the macro is bound
// under its own name.
//
// Inputs/macro_import_by_name: lib.k declares the macros, each other file
// is one importer.

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: cd %S/Inputs/macro_import_by_name && %kairo named.k -o %t.d/named --cache-dir %t.d/c
// RUN: %t.d/named; test $? -eq 42
// RUN: cd %S/Inputs/macro_import_by_name && %kairo braced.k -o %t.d/braced --cache-dir %t.d/c
// RUN: %t.d/braced; test $? -eq 43

// RUN: cd %S/Inputs/macro_import_by_name && { %kairo alias.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=ALIAS
// ALIAS: alias.k:1:24: error [R001E]: a macro import takes no 'as': import it as 'getter!' and invoke 'getter!'
// ALIAS: alias.k:2:24: error [R001E]: a macro import takes no 'as': import it as 'twice!' and invoke 'twice!'
// ALIAS-NOT: R015E

// RUN: cd %S/Inputs/macro_import_by_name && { %kairo priv.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=PRIV
// PRIV: priv.k:1:1: error [R011E]: macro 'hidden!' is not visible here
// PRIV-NOT: R015E

// RUN: cd %S/Inputs/macro_import_by_name && { %kairo bare_used.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=USED
// USED: bare_used.k:2:27: error [R013E]: unknown macro 'getter!': its import names 'getter' without the '!'
// USED-NEXT: fix-it:"{{.*}}bare_used.k":{1:19-1:19}:"!"
// USED-NEXT: bare_used.k:1:13: note [{{.*}}]: 'getter' without '!' imports a declaration; a macro is imported as 'getter!'

// RUN: cd %S/Inputs/macro_import_by_name && { %kairo bare_unused.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=UNUSED
// UNUSED: bare_unused.k:1:14: error [R015E]: 'getter' is not declared in module 'lib'
// UNUSED-NEXT: fix-it:"{{.*}}bare_unused.k":{1:20-1:20}:"!"
// UNUSED-NEXT: note [{{.*}}]: 'getter!' is a macro there; a macro is imported with its '!'
// UNUSED-NOT: error
