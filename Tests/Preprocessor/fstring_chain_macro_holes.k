// Adjacent literals join whatever their prefixes, so an f-string's
// holes can sit in a later segment of a chain whose head is plain
// (`"v=" f"{x}"`). The preprocessor's hole rewrite (PPWalker::_subst_fstring,
// _expand_fstring) must not read the head segment only: a macro parameter or
// an invocation in a later segment's hole would reach the parser raw (R020E).
// Every segment is copied and rewritten, the chain relinked in the
// expanding file's table: same-file macros, a parameter next to an
// invocation, and an imported file's macros, whose segments and holes read
// that file's names and literals.
//
// Inputs/fstring_chain: main.k (the input) imports lib.k.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/fstring_chain && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/fstring_chain && %kairo main.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT:      v=1
// OUT-NEXT: v=8
// OUT-NEXT: v=42
// OUT-NEXT: <7:42>
// OUT-NEXT: s=5 t=10
// OUT-NEXT: \f=40!
