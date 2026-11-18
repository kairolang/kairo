// -fno-rtti is forwarded; RTTI is cc1's default so -frtti adds nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-rtti || true; } | %FileCheck %s --check-prefix=OFF
// OFF: -fno-rtti
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -frtti || true; } | %FileCheck %s --check-prefix=ONN
// ONN-NOT: rtti
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: rtti
