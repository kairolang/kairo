// The glibc recipe's compiler-rt dir is the one clang searches: clang looks
// for crtbegin and libclang_rt.builtins.a only under lib/<normalized triple>,
// which carries the vendor (x86_64-unknown-linux-gnu, also for
// --target=x86_64-linux-gnu). A vendorless dir is invisible to every clang
// handed a glibc target and -resource-dir=<root>/compiler-rt.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t && mkdir -p %t
// RUN: python3 %S/inputs/glibc_rt_dir.py %clang_c %t > %t/out
// RUN: %FileCheck %s < %t/out
// RUN: %FileCheck %s --check-prefix=NONE < %t/out
// CHECK: x86_64 x86_64-linux-gnu: ok
// CHECK: x86_64 x86_64-unknown-linux-gnu: ok
// CHECK: armv7 armv7-linux-gnueabihf: ok
// CHECK: armv7 armv7-unknown-linux-gnueabihf: ok
// CHECK: x32 x86_64-linux-gnux32: ok
// CHECK: mips64 mips64-linux-gnu: ok
// CHECK: sparc64 sparc64-unknown-linux-gnu: ok
// NONE-NOT: MISSING
