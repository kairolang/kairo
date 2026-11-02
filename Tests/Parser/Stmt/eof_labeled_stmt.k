// A label `v :` whose loop is missing because the file ends: the loop-keyword
// check resolved the null cursor. The code must stay the last bytes of the file.
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_labeled_stmt.k:9:11: error [S059E]: a label may only be applied to a loop

i32 > var v :