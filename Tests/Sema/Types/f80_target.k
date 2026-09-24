// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=HOST --allow-empty
// RUN: { %kairo %s --type-check-only --target=aarch64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=ARM64
// RUN: { %kairo %s --type-check-only --target=riscv64-unknown-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=RISCV
// RUN: { %kairo %s --type-check-only --target=i386-pc-linux-gnu 2>&1 || true; } | %FileCheck %s --check-prefix=X86 --allow-empty
// RUN: { %kairo %s --type-check-only -m32 2>&1 || true; } | %FileCheck %s --check-prefix=M32 --allow-empty
//
// `f80` is the x87 80-bit extended format: 1/15/64 with an EXPLICIT integer
// bit, which no IEEE interchange format has. It is a property of the x87
// register stack, so it exists on x86 and x86_64 and nowhere else -- on every
// other target C's `long double` is simply `double`.
//
// CanonicalNodes.k's BuiltinKind::F80 comment has always promised a hard error
// naming the target triple here, rather than a silent widen to f128 or narrow
// to f64. This file is that promise, on both sides:
//
//   - rejected on aarch64 and riscv64, with the REASON and the effective
//     triple in the message (a bare "not supported" leaves the user guessing
//     whether it is a compiler limitation or a real property of their target);
//   - accepted on i386, and accepted on the x86_64 host under -m32, because
//     -m32 is an arch-VARIANT rewrite and i386 still has x87. A check written
//     against pointer width instead of ISA gets that one wrong.
//
// The target facts come from TargetOptions' derived block, filled once by
// CompilerInstance::_apply_invocation off a single llvm::Triple, so the ISA
// answer here and the pointer width usize gets can never disagree about which
// target this is.

fn main() -> i32 {
    var x: f80 = 1.0;
    return 0;
}

// This suite's own host is x86_64, so nothing is diagnosed here.
// HOST-NOT: P003E

// The message has to carry WHY, not just a refusal: the feature that is
// missing (x87) and the target that is missing it, then where that target came
// from, then what to use instead.
// ARM64: error [P003E]: 'f80' requires x87, which aarch64 does not have
// ARM64: note [I900N]: the effective target is 'aarch64-unknown-linux-gnu'
// ARM64-SAME: --target if given, else the host triple
// ARM64: note [I900N]: use 'f64'
// ARM64-SAME: or 'f128' for the wider range

// RISCV: error [P003E]: 'f80' requires x87, which riscv64 does not have
// RISCV: note [I900N]: the effective target is 'riscv64-unknown-linux-gnu'

// 32-bit x86 still has an x87 stack.
// X86-NOT: P003E

// -m32 rewrites x86_64 to i386; it does not stop being x86.
// M32-NOT: P003E
