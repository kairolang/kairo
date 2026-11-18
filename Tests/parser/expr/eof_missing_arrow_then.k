// An `if` expression's then-arm is missing at end of file: S074E's location
// came from the null cursor. It is now anchored just past the last token. The
// code must stay the last bytes of the file (no trailing newline).
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_missing_arrow_then.k:10:11: error [S074E]: expected '=>' after condition

if if main