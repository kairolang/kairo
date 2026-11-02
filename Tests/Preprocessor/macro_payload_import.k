// Literals in a macro body defined in ANOTHER file, read through the macro
// wrapper (macros.mdx: a macro expands to its body's tokens). Each read the
// expanding file's tables with the wrapped token, or the body's raw tokens:
//
// - `t.1` in a body was S054E "no whitespace allowed" for every expansion:
//   both tokens carry the invocation's range, so they looked spaced apart
//   (a same-file macro too: `third!`). The index's value came from this
//   file's literal list.
// - a two-part string `"ab" "cd"` followed its chain in the expanding
//   file's table (StringLowering): a null or a different literal.
// - an f-string's hole tokens are lib.k's, so `helper_fn` was R020E.
// - `inline "c++"` in a body was S060E: the language string's kind was
//   read off the wrapper.
//
// Inputs/macro_payload_import: main.k (the input) imports lib.k;
// inline_main.k expands lib.k's `mark!()`, type-checked only.

// --- lit wiring -----------------------------------------------------------
// RUN: cd %S/Inputs/macro_payload_import && { %kairo main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: cd %S/Inputs/macro_payload_import && { %kairo inline_main.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: cd %S/Inputs/macro_payload_import && %kairo main.k -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out; test $? -eq 50
// RUN: %FileCheck %s --check-prefix=OUT < %t.out
// OUT:      abcd
// OUT-NEXT: v=42
