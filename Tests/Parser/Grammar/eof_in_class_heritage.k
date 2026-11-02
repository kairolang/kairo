// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE
// A class heritage clause cut off by EOF after `derives` read the null cursor.
// Fuzzer finding 1879ef522a: this used to segfault. The crash handler exits 1,
// so `not` alone passes on a crash too: --implicit-check-not on the crash
// banner is what checks "no crash"; the `not` line checks "rejected".
// The input must stay the last line, with NO trailing newline: the crash
// needed EOF right there, and a newline token in between hides it.
// CHECK: :[[@LINE+1]]:16: error [S053E]: expected a type after 'derives'
class D derives