// A bare cc1 line has exceptions off, so only -fexceptions has anything to add:
// it enables C++ exceptions in the interop compiler. -fno-exceptions adds nothing.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fexceptions || true; } | %FileCheck %s --check-prefix=ON
// ON: -fcxx-exceptions -fexceptions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl -fno-exceptions || true; } | %FileCheck %s --check-prefix=OFFN
// OFFN-NOT: -fexceptions
// RUN: { %kairo %s --print-clang-args --target=x86_64-linux-musl || true; } | %FileCheck %s --check-prefix=DEFN
// DEFN-NOT: -fcxx-exceptions
