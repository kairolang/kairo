// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE
// A generic parameter bound cut off by EOF after `impl` read the null cursor.
// Fuzzer finding 1e62515e94: this used to segfault. The crash handler exits 1,
// so `not` alone passes on a crash too: --implicit-check-not on the crash
// banner is what checks "no crash"; the `not` line checks "rejected".
// The input must stay the last line, with NO trailing newline: the crash
// needed EOF right there, and a newline token in between hides it.
// CHECK-DAG: :[[@LINE+2]]:{{[0-9]+}}: error [S053E]: expected a type after 'impl'
// CHECK-DAG: :[[@LINE+1]]:4: error [S049E]: expected '>' to close generic parameter list
fn < T impl