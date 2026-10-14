// --m32 rewrites the arch of --target to its 32-bit variant (and --m64 to its
// 64-bit one), so the cc1 -triple agrees with the sysroot picked with the same
// rewrite. Left at x86_64 it compiled 64-bit code against 32-bit headers.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --m32 || true; } | %FileCheck %s --check-prefix=M32
// M32: -triple i{{[36]86}}-
// RUN: { %kairo %s --print-clang-args --target=i686-linux-musl --m64 || true; } | %FileCheck %s --check-prefix=M64
// M64: -triple x86_64-
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEF
// DEF: -triple x86_64-
