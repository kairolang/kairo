// cc1 keeps no frame pointer unless told, so both directions are spelled out:
// -fomit-frame-pointer is -mframe-pointer=none, -fno-omit-frame-pointer is
// -mframe-pointer=all.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fomit-frame-pointer || true; } | %FileCheck %s --check-prefix=OMIT
// OMIT: -mframe-pointer=none
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-omit-frame-pointer || true; } | %FileCheck %s --check-prefix=KEEP
// KEEP: -mframe-pointer=all
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -mframe-pointer
