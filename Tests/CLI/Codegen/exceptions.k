// C++ exceptions are on by default for a hosted target: a Kairo TU's C++
// includes C++ headers that throw, and an exception must reach a Kairo frame
// to be stopped there (every Kairo function is noexcept) or passed on
// (`@unwind`, -funwind). A bare cc1 line has them off, so the default and
// -fexceptions both add -fcxx-exceptions -fexceptions; -fno-exceptions adds
// nothing. A freestanding target (no OS in the triple) has no unwinder and
// keeps them off unless -fexceptions asks.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fexceptions || true; } | %FileCheck %s --check-prefix=ON
// ON: -fcxx-exceptions -fexceptions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-exceptions || true; } | %FileCheck %s --check-prefix=OFFN
// OFFN-NOT: -fexceptions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=ON
// RUN: { %kairo %s --print-clang-args --target=thumbv6m-none-eabi || true; } | %FileCheck %s --check-prefix=OFFN
// RUN: { %kairo %s --print-clang-args --target=thumbv6m-none-eabi -fexceptions || true; } | %FileCheck %s --check-prefix=ON
