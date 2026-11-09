// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE --implicit-check-not=runtime
// A closure signature (_parse_closure_sig) cut off by EOF inside its parameter list.
// Fuzzer finding crash/e42e54b36f: the parser read prev_ptr() unguarded right
// after the list, and two advances past the last token leave it null
// (UBSan null Token, then a segfault). --implicit-check-not on the crash
// banner checks "no crash"; the `not` line checks "rejected".
// The input must stay last, with NO trailing newline: the crash needed EOF
// right there.
// CHECK: :[[@LINE+1]]:4: error [S047E]: expected ')' to close the parameter list
fn ( fn ( [ 