// The input stops right after a keyword the primary-expression parser rejects
// and steps over ('panic' inside an array literal). The cursor is then past
// the last token, and the "no production matched" path resolved that null
// cursor. It must report and exit, not fault. The code must stay the last
// bytes of the file (no trailing newline): stopping there is the bug.
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_after_rejected_keyword.k:13:1: error [S054E]: expected ']' to close array literal
// CHECK: eof_after_rejected_keyword.k:13:3: error [S052E]: 'panic' is not valid in this position of an expression

[ panic