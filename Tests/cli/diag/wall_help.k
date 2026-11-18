// --Wall/--Wextra/--Wpedantic only forward to clang for the generated C++;
// no Kairo diagnostic is gated by them, and the help now says so.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --help | %FileCheck %s
// CHECK: --Wall{{.*}}forwarded to clang for the generated C++; no Kairo diagnostic is gated
// CHECK: --Wextra{{.*}}forwarded to clang for the generated C++; no Kairo diagnostic is gated
// CHECK: --Wpedantic{{.*}}forwarded to clang for the generated C++; no Kairo diagnostic is gated
