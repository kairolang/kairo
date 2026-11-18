// Every fixed-width <stdint.h> typedef imports as the Kairo integer of the
// same width and signedness on every data model. The import keys on the
// clang type's width, not its builtin kind: uint64_t is `unsigned long` on
// LP64 Linux and `unsigned long long` on LLP64 Windows and on 32-bit
// targets, and a kind-keyed table with LP64 widths baked in once read the
// LLP64 spelling as u32 -- which broke every 64-bit integer crossing FFI on
// Windows.
//
// Each pair below is two-sided: `uN -> uintN_t` rejects an import NARROWER
// than N, `uintN_t -> uN` rejects one WIDER than N or of the other
// signedness, so both lines type only when the import is exactly uN.

ffi "c++" import "stdint.h"

fn widths(a8: u8, a16: u16, a32: u32, a64: u64, b8: i8, b16: i16, b32: i32, b64: i64) {
    var u8_: uint8_t = a8;    var r8: u8 = u8_
    var u16_: uint16_t = a16; var r16: u16 = u16_
    var u32_: uint32_t = a32; var r32: u32 = u32_
    var u64_: uint64_t = a64; var r64: u64 = u64_
    var s8_: int8_t = b8;     var q8: i8 = s8_
    var s16_: int16_t = b16;  var q16: i16 = s16_
    var s32_: int32_t = b32;  var q32: i32 = s32_
    var s64_: int64_t = b64;  var q64: i64 = s64_
}

// --- lit wiring -----------------------------------------------------------
// Each cross target needs its own C library headers (a host libc read for
// another target makes uint64_t 32 bits on Windows); the msvc sysroots are
// not redistributable, so the file is UNSUPPORTED where they are missing.
// REQUIRES: sysroot-x86_64-windows-msvc
// REQUIRES: sysroot-i686-windows-msvc
// REQUIRES: sysroot-aarch64-windows-msvc
// REQUIRES: sysroot-x86_64-linux-gnu
// RUN: { %kairo %s --type-check-only --target=x86_64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target=x86_64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target=i686-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --target=aarch64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
