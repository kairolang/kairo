// --unwind-tables is -funwind-tables=0|1|2 after the target probe's own (async,
// 2, on x86_64); cc1 takes the last, so the flag wins. Not given, nothing changes.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --unwind-tables=none || true; } | %FileCheck %s --check-prefix=NONE
// NONE: -funwind-tables=2
// NONE: -funwind-tables=0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --unwind-tables=sync || true; } | %FileCheck %s --check-prefix=SYNC
// SYNC: -funwind-tables=2
// SYNC: -funwind-tables=1
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --unwind-tables=async || true; } | %FileCheck %s --check-prefix=ASYNC
// ASYNC: -funwind-tables=2
// ASYNC: -funwind-tables=2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEF
// DEF: -funwind-tables=2
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -funwind-tables={{[01]}}
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --unwind-tables=bogus 2>&1 || true; } | %FileCheck %s --check-prefix=BAD
// BAD: error [U003E]: invalid value 'bogus' for flag '--unwind-tables'; accepted: none, sync, async
