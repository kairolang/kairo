// RUN: not %kairo %s --syntax-only > /dev/null 2>&1
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=PLEASE
// A type body cut off by EOF after a bare `@` handed resolve_deep a null token.
// Found by fuzzing: this used to segfault. The crash handler exits 1,
// so `not` alone passes on a crash too: --implicit-check-not on the crash
// banner is what checks "no crash"; the `not` line checks "rejected".
// The input must stay the last line, with NO trailing newline: the crash
// needed EOF right there, and a newline token in between hides it.
// CHECK: :[[@LINE+3]]:5: error [S046E]: expected attribute name after '@'
// CHECK: :[[@LINE+2]]:5: error [S048E]: expected '}' to close the type body
class Neither {
    @