// --unmatched picks what an exhaustive match lowers to for a value no arm
// covers. Tests/Sema/Pattern/unmatched_flag.k only checks the flag is
// accepted; this pins the lowering: unreachable emits the IR instruction,
// trap emits a call to llvm.trap instead.

enum E { A, B }
fn f(e: E) -> i32 {
    return match e {
        case E::A => 1
        case E::B => 2
    }
}
fn main() -> i32 { return f(E::A) }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t && mkdir -p %t
// RUN: %kairo %s --emit=llvm-ir --cache-dir=%t --unmatched=unreachable
// RUN: %FileCheck %s --check-prefix=UNREACH < %t/unmatched.ll
// UNREACH-NOT: llvm.trap
// UNREACH: unreachable
// RUN: %kairo %s --emit=llvm-ir --cache-dir=%t --unmatched=trap
// RUN: %FileCheck %s --check-prefix=TRAP < %t/unmatched.ll
// TRAP: llvm.trap
// TRAP-NOT: unreachable
