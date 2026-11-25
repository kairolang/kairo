// A source file rewritten while a compile of it runs (an editor saving, a
// script editing the tree, a checkout): the compile uses the bytes it read,
// on its own side and on clang's. It may report syntax errors when it read
// the file half written, but it does not crash, and a program it builds is
// one of the file's texts. The inputs script races 20 compiles against a
// thread that rewrites an imported file in place and by rename.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: python3 %S/inputs/source_rewritten_during_build.py %kairo_bin %t.d 20 240 | %FileCheck %s
// CHECK: compiles some
// CHECK-NEXT: signal 0
// CHECK-NEXT: ice 0
// CHECK-NEXT: wrong 0
// CHECK-NEXT: quiet compile 0
// CHECK-NEXT: quiet run 7
