// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE
// An enum body cut off by EOF after a stray `pub` read the null cursor.
// Fuzzer finding acd92959e4: this used to segfault. The crash handler exits 1,
// so `not` alone passes on a crash too: --implicit-check-not on the crash
// banner is what checks "no crash"; the `not` line checks "rejected".
// The input must stay the last line, with NO trailing newline: the crash
// needed EOF right there, and a newline token in between hides it.
// CHECK-DAG: :[[@LINE+2]]:{{[0-9]+}}: error [S048E]: expected variant name in enum body
// CHECK-DAG: :[[@LINE+1]]:1: error [S048E]: expected '}' to close the enum body
enum Opt { pub