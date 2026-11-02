// A macro defined in one file and expanded in another to an integer literal
// is that literal (macros.mdx: a macro expands to its body's tokens), also
// when the expanding file is an IMPORTED, non-input file.
//
// Inputs/macro_int_literal: main.k (the input) imports user.k, which
// imports defs.k and returns `defs::seven!()`, a macro whose body is `7`.
//
// It was SC073E "integer literal has no immediate data" at user.k's
// `defs::seven!()`: the literal reached the parser macro-wrapped, its imm
// the expansion record, and IntegerLiteralExpr read that index against
// user.k's literal list instead of the payload in defs.k's table. The run
// also covers EmitIR, which borrowed the invocation's bytes (`seven!()`)
// as the numeric constant.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_int_literal && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/macro_int_literal && %kairo main.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
