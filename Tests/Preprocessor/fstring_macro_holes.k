// An f-string is one token, and its holes are token buffers the
// preprocessor's walk never visited. A macro parameter written in a hole
// (`macro g!(x) { f"v={x}" }`) was not substituted and an invocation in a
// hole (`f"v={m!}"`) was not expanded: the parser met the raw `x` / `m`
// (R020E). Both now go through the walk (PPWalker::_subst_fstring,
// _expand_fstring): same-file macros, nested ones, a parameter next to an
// invocation, and macros of an imported file, whose holes read that file's
// names and literals.
//
// Inputs/fstring_holes: main.k (the input) imports lib.k.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/fstring_holes && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/fstring_holes && %kairo main.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT:      v=1
// OUT-NEXT: v=8
// OUT-NEXT: v=42
// OUT-NEXT: v=3
// OUT-NEXT: 7:42:8
// OUT-NEXT: s=5 t=10
// OUT-NEXT: f=40
