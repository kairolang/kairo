// RUN: %kfmt --stdout %s | diff -u %S/expected/import_many_names.k -
// RUN: %kfmt --check %S/expected/import_many_names.k
//
// Section 5.2: a braced import of seven or more names is one name per line,
// four spaces in, sorted. It is never a column grid, which pads a column to
// its widest name (`decl_extension_of,    decl_is_ctor`).

import AST::DeclFacts::{
    decl_extension_of,    decl_is_ctor, decl_is_ffi, decl_is_imported, decl_name_tok, decl_pattern,
    decl_requires_clause,
}

fn f() { }
