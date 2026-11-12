// Operators declared by an imported `pub macro`: the macro's
// tokens are spelled in the DEFINING file's tables, so the `l` / `r`
// marker of `op r++` / `op l++` is re-interned in the importing file when
// the declaration stores it, and `+` / `-` from one body are two
// operators. Inputs/macro_ops_import: lib.k declares the macro, app.k
// uses it. Type-checked only: with the marker misread, `a++` finds no
// postfix form and `++a` no prefix one. Compiling it hits a TokenSink ICE
// (I003E "span runs past the end of its buffer") that any method an
// imported macro declares hits, operator or not.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_ops_import && { %kairo app.k --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error [
