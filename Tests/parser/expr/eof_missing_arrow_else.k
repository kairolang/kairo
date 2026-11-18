// Same as eof_missing_arrow_then, for the final `else` arm: the file ends
// right after `else`. The code must stay the last bytes of the file.
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_missing_arrow_else.k:10:10: error [S074E]: expected '=>' after condition
// CHECK: eof_missing_arrow_else.k:10:16: error [S074E]: expected '=>' after 'else'

x = if c 1 else