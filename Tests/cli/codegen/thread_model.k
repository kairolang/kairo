// --thread-model=single is -mthread-model single; posix is cc1's default and adds
// nothing. Anything else is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --thread-model=single || true; } | %FileCheck %s --check-prefix=ONE
// ONE: -mthread-model single
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --thread-model=posix || true; } | %FileCheck %s --check-prefix=POSIXN
// POSIXN-NOT: -mthread-model
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --thread-model=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--thread-model'; accepted: posix, single
