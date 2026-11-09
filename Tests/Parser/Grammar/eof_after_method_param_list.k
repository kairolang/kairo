// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE --implicit-check-not=runtime
// An out-of-line method's parameter list cut off by EOF inside a tuple type.
// Fuzzer finding crash/7bc32f70b1: the parser read prev_ptr() unguarded right
// after the list, and two advances past the last token leave it null
// (UBSan null Token, then a segfault). --implicit-check-not on the crash
// banner checks "no crash"; the `not` line checks "rejected".
// The input must stay last, with NO trailing newline: the crash needed EOF
// right there.
// CHECK: :[[@LINE+1]]:11: error [S047E]: expected ')' to close the parameter list
fn S :: h ( ( self , 