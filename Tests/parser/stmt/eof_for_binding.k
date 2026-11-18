// The file ends right after `for `: the binding parser took its start range
// from the null cursor. The code must stay the last bytes of the file (here
// `for` and one space, no newline).
//
// REQUIRES: shell
// RUN: timeout 10 %kairo %s --syntax-only > %t.out 2>&1; test $? -eq 1
// RUN: %FileCheck %s --input-file=%t.out --implicit-check-not=PLEASE --implicit-check-not=Sanitizer
// CHECK: eof_for_binding.k:11:1: error [S059E]: expected ';' after for-loop initializer
// CHECK: eof_for_binding.k:11:4: error [S058E]: expected binding name or '_' in binding

for 