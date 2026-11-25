// An integer `as` bf16 compiles for every target from every integer width,
// a 128-bit one on AArch64 and a 64-bit one on i686 included: LLVM has no
// runtime routine for those conversions there, and instruction selection
// aborted on the plain conversion. The cast rounds through a sticky f32
// instead (int_to_bf16_rounding_run.k runs it). Compile only.

fn from_i32(x: i32) -> bf16 { return x as bf16 }
fn from_u32(x: u32) -> bf16 { return x as bf16 }
fn from_i64(x: i64) -> bf16 { return x as bf16 }
fn from_u64(x: u64) -> bf16 { return x as bf16 }
fn from_i128(x: i128) -> bf16 { return x as bf16 }
fn from_u128(x: u128) -> bf16 { return x as bf16 }
fn from_i256(x: i256) -> bf16 { return x as bf16 }
fn from_u512(x: u512) -> bf16 { return x as bf16 }
fn from_isize(x: isize) -> bf16 { return x as bf16 }
fn from_usize(x: usize) -> bf16 { return x as bf16 }
fn opt_i128(x: i128) -> bf16? { return x as bf16? }
fn back_i128(x: bf16) -> i128 { return x as i128 }
fn back_u128(x: bf16) -> u128 { return x as u128 }

fn main(argc: i32) -> i32 {
    var x = argc as i128
    if back_i128(from_i128(x)) != x { return 1 }
    if back_u128(from_u128(x as u128)) != x as u128 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-aarch64-linux-musl
// RUN: rm -f %t.*.o
// RUN: %kairo %s --target=aarch64-linux-musl -c -o %t.aarch64.o
// RUN: %if sysroot-i686-linux-musl %{ %kairo %s --target=i686-linux-musl -c -o %t.i686.o %}
// RUN: %if sysroot-armv7-linux-musl %{ %kairo %s --target=armv7-linux-musl -c -o %t.armv7.o %}
// RUN: %if sysroot-riscv64-linux-musl %{ %kairo %s --target=riscv64-linux-musl -c -o %t.riscv64.o %}
// x86_64, which compiled before, still does.
// RUN: %if sysroot-x86_64-linux-musl %{ %kairo %s --target=x86_64-linux-musl -c -o %t.x86_64.o %}
