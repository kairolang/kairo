// --source-date-epoch is cc1's -source-date-epoch: it fixes __DATE__, __TIME__ and
// __TIMESTAMP__ in C and C++ sources. Kairo objects carry no other timestamp.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl --source-date-epoch=1700000000 || true; } | %FileCheck %s --check-prefix=EPOCH
// EPOCH: -source-date-epoch 1700000000
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -source-date-epoch
