// -ftrap-unreachable has no cc1 spelling; it is LLVM's trap-unreachable option,
// forwarded as an -mllvm word (and applied by the backend, since the in-process
// clang does not run cc1_main's -mllvm handling).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -ftrap-unreachable || true; } | %FileCheck %s --check-prefix=ON
// ON: -mllvm -trap-unreachable
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -trap-unreachable
