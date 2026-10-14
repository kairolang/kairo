// --no-timestamps is --source-date-epoch=0; an explicit epoch wins.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --no-timestamps || true; } | %FileCheck %s --check-prefix=ZERO
// ZERO: -source-date-epoch 0
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --no-timestamps --source-date-epoch=5 || true; } | %FileCheck %s --check-prefix=FIVE
// FIVE: -source-date-epoch 5
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --no-timestamps --source-date-epoch=5 || true; } | %FileCheck %s --check-prefix=FIVEN
// FIVEN-NOT: -source-date-epoch 0
