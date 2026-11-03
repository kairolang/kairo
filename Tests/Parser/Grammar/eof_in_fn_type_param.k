// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE --implicit-check-not=runtime
// A generic method's fn-typed parameter cut off by EOF inside an extend block.
// Fuzzer finding crash/87dc7b2d77 (P278): the parser read prev_ptr() unguarded right
// after the list, and two advances past the last token leave it null
// (UBSan null Token, then a segfault). --implicit-check-not on the crash
// banner checks "no crash"; the `not` line checks "rejected".
// The input must stay last, with NO trailing newline: the crash needed EOF
// right there.
// CHECK: :[[@LINE+3]]:16: error [S047E]: expected ')' to close the parameter list
extend < > Cell {
    { }
    fn < > map ( f : fn ( fn 