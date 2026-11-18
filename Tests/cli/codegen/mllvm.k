// --mllvm forwards a word to LLVM's option parser (-mllvm <word>), in order,
// after the words the other flags lower to so a user word can override them.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --mllvm=-enable-misched=0 --mllvm=-x86-cmov-converter=0 || true; } | %FileCheck %s --check-prefix=TWO
// TWO: -mllvm -enable-misched=0 -mllvm -x86-cmov-converter=0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -mllvm
