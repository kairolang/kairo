// A macro defined in one file and expanded in another to an integer literal
// is that literal (macros.mdx: a macro expands to its body's tokens), also
// when the expanding file is an IMPORTED, non-input file.
//
// Inputs/macro_int_literal: main.k (the input) imports user.k, which
// imports defs.k and returns `defs::seven!()`, a macro whose body is `7`.
//
// XFAIL: *
// Ticket "[Preprocessor/Sema] SC073E \"integer literal has no immediate
// data\" for a macro from another file expanding to an integer literal"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-24). Today: SC073E at user.k's
// `defs::seven!()` -- the literal token's immediate lives in defs.k's
// table, and user.k's lookup does not find it. qualified_macro.k steps
// around it with `bool` macros. When it XPASSes, delete the XFAIL -- the
// runs below are already the real assertion.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_int_literal && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/macro_int_literal && %kairo main.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
