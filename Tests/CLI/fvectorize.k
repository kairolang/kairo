// -fno-vectorize removes the loop and SLP vectorizer from the cc1 invocation
// that -O2 enables; -fvectorize at -O2 changes nothing (already on).

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -O2 --print-clang-args | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s -O2 -fvectorize --print-clang-args | %FileCheck %s --check-prefix=ON
// RUN: %kairo %s -O2 -fno-vectorize --print-clang-args | %FileCheck %s --check-prefix=OFF
// ON: -vectorize-loops
// ON: -vectorize-slp
// OFF-NOT: -vectorize-loops
// OFF-NOT: -vectorize-slp
