// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=HOST --allow-empty
// RUN: { %kairo %s --type-check-only --target=x86_64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=X64 --allow-empty
// RUN: { %kairo %s --type-check-only --target=aarch64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// RUN: { %kairo %s --type-check-only --target=riscv64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=RISCV
// RUN: { %kairo %s --type-check-only --target=aarch64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=ARMWIN
// RUN: { %kairo %s --type-check-only --target=x86_64-pc-windows-msvc 2>&1 || true; } | %FileCheck %s --check-prefix=MSVC
// RUN: { %kairo %s --type-check-only --target=x86_64-unknown-linux-android 2>&1 || true; } | %FileCheck %s --check-prefix=ANDROID
// RUN: { %kairo %s --type-check-only --target=i386-pc-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=X86 --allow-empty
// RUN: { %kairo %s --type-check-only -m32 2>&1 || true; } | %FileCheck %s --check-prefix=M32 --allow-empty
//
// `f80` is the x87 80-bit extended format: 1/15/64 with an EXPLICIT integer
// bit, which no IEEE interchange format has. It lowers to C++ `long double`,
// so it exists exactly where the target ABI's `long double` IS x87 extended.
// That is an ABI fact, not an ISA fact, and the two diverge on x86 itself:
// x86_64-windows-msvc has x87 hardware and a binary64 `long double`,
// x86_64-linux-android a binary128 one. Off x86 the answer varies too --
// binary128 on AArch64/RISC-V Linux, binary64 on Windows on ARM -- so "use
// f64" is not a universal fix either.
//
// CanonicalNodes.k's BuiltinKind::F80 comment has always promised a hard error
// naming the target triple here, rather than a silent widen to f128 or narrow
// to f64. This file is that promise, on both sides:
//
//   - rejected wherever `long double` is not x87, with the REASON (no x87 at
//     all, or x87 the ABI does not expose) and the effective triple in the
//     message, and a fix naming the type `long double` actually is there;
//   - accepted on x86_64 SysV and i386, and on the x86_64 host under -m32,
//     because -m32 is an arch-VARIANT rewrite and i386 Linux still makes
//     `long double` x87. A check written against pointer width instead of
//     the ABI gets that one wrong.
//
// The facts come from TargetOptions' derived block, filled once by
// CompilerInstance::_apply_invocation off a single llvm::Triple and a
// clang::TargetInfo built for it, so the `long double` answer here and the
// pointer width usize gets can never disagree about which target this is.

fn main() -> i32 {
    var x: f80 = 1.0;
    return 0;
}

// This suite's own host is x86_64 Linux, so nothing is diagnosed here.
// HOST-NOT: P003E
// X64-NOT: P003E

// The message has to carry WHY, not just a refusal: the feature that is
// missing (x87) and the target that is missing it, then where that target came
// from, then what to use instead.
// ARM64: error [P003E]: 'f80' requires x87, which aarch64 does not have
// ARM64: note [I900N]: the effective target is 'aarch64-unknown-linux-gnu'
// ARM64-SAME: --target if given, else the host triple

// RISCV: error [P003E]: 'f80' requires x87, which riscv64 does not have
// RISCV: note [I900N]: the effective target is 'riscv64-unknown-linux-gnu'

// Windows on ARM: `long double` is binary64.
// ARMWIN: error [P003E]: 'f80' requires x87, which aarch64 does not have
// ARMWIN: note [I900N]: use 'f64' (what C's 'long double' is on this target)

// x87 hardware, binary64 ABI: the has-x87 wording, and the format named.
// MSVC: error [P003E]: 'f80' is unavailable on 'x86_64-pc-windows-msvc': x87 exists but this ABI's 'long double' is binary64
// MSVC: note [I900N]: use 'f64' (what C's 'long double' is on this target)

// x87 hardware, binary128 ABI.
// ANDROID: error [P003E]: 'f80' is unavailable on 'x86_64-unknown-linux-android': x87 exists but this ABI's 'long double' is binary128

// 32-bit x86 Linux: x87, stored in 12 bytes rather than 16.
// X86-NOT: P003E

// -m32 rewrites x86_64 to i386; its `long double` is still x87.
// M32-NOT: P003E
