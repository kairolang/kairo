// The cold grower takes the preserve_most convention on every x86-64 and
// AArch64 ABI family clang is asked to build it for, and the plain C one
// elsewhere (the attribute is guarded by architecture). Compile-only.
// x32 and aarch64_be have no bundled sysroot and are not covered here.

pub fn push_i32(v: *[i32], x: i32) {
    v->push(x)
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib, sysroot-x86_64-windows-gnu, sysroot-x86_64-windows-msvc, sysroot-aarch64-windows-msvc, sysroot-arm64-macosx, sysroot-armv7-linux-gnueabihf, sysroot-riscv64-linux-gnu
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=x86_64-windows-gnu -o %t.wgnu.ll --cache-dir %t.d/wgnu
// RUN: %FileCheck %s --check-prefix=PM < %t.wgnu.ll
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=x86_64-windows-msvc -o %t.wmsvc.ll --cache-dir %t.d/wmsvc
// RUN: %FileCheck %s --check-prefix=PM < %t.wmsvc.ll
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=aarch64-windows-msvc -o %t.a64w.ll --cache-dir %t.d/a64w
// RUN: %FileCheck %s --check-prefix=PM < %t.a64w.ll
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=arm64-apple-macosx11.0 -o %t.mac.ll --cache-dir %t.d/mac
// RUN: %FileCheck %s --check-prefix=PM < %t.mac.ll
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=armv7-linux-gnueabihf -o %t.arm.ll --cache-dir %t.d/arm
// RUN: %FileCheck %s --check-prefix=PLAIN < %t.arm.ll
// RUN: %kairo_new %s -O2 --emit=llvm-ir --target=riscv64-linux-gnu -o %t.rv.ll --cache-dir %t.d/rv
// RUN: %FileCheck %s --check-prefix=PLAIN < %t.rv.ll

// PM-LABEL:    define {{.*}}push_i32
// PM:          {{ call }}preserve_mostcc {{.*}}grow_bytes

// PLAIN-LABEL: define {{.*}}push_i32
// PLAIN-NOT:   preserve_most
// PLAIN:       {{ call }}{{.*}}grow_bytes
// PLAIN-NOT:   preserve_most
