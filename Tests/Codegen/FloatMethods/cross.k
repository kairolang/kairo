// The float methods off the host: methods.k and half_oracle.k built for
// i686 (x87 f80, f128 and every fma a libcall, SSE2 f32 / f64) and aarch64
// (no f80; f128 is long double) against their ksys roots, run under qemu.
// methods.k's X87 lines are checked on i686 only.

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang, qemu-i386, qemu-aarch64
// REQUIRES: sysroot-i686-linux-musl, sysroot-aarch64-linux-musl
// RUN: rm -rf %t.d
// RUN: %kairo %S/methods.k --target=i686-linux-musl -o %t.m32 --cache-dir %t.d
// RUN: %qemu_i386 %t.m32 | %FileCheck %S/methods.k --check-prefixes=CHECK,X87
// RUN: %kairo %S/methods.k --target=aarch64-linux-musl -o %t.m64 --cache-dir %t.d
// RUN: %qemu_aarch64 %t.m64 | %FileCheck %S/methods.k
// RUN: %kairo %S/half_oracle.k --target=i686-linux-musl -O2 -o %t.h32 --cache-dir %t.d
// RUN: %qemu_i386 %t.h32 | %FileCheck %S/half_oracle.k
// RUN: %kairo %S/half_oracle.k --target=aarch64-linux-musl -O2 -o %t.h64 --cache-dir %t.d
// RUN: %qemu_aarch64 %t.h64 | %FileCheck %S/half_oracle.k
