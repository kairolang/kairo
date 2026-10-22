// -c -o, -S -o and --emit=asm -o name the output of the ONE user translation
// unit. The builtin and std modules are TUs too; they used to count as
// outputs, so -o failed with I004F for every ordinary program. They go under
// --cache-dir instead. With two user TUs there is no single name, and the
// I004F refusal stays.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c -o %t.o --cache-dir=%t.d
// RUN: test -s %t.o
// RUN: %kairo %s -S -o %t.s --cache-dir=%t.d
// RUN: %FileCheck %s --input-file=%t.s
// CHECK: main
// RUN: %kairo %s --emit=asm -o %t.emit.s --cache-dir=%t.d
// RUN: test -s %t.emit.s
// RUN: { %kairo %s %S/Inputs/other_unit.k -c -o %t.two.o --cache-dir=%t.d 2>&1 || true; } | %FileCheck %s --check-prefix=TWO
// TWO: fatal [I004F]: -o {{.*}}.two.o names one output, but this build emits 2
