// --print-cxx dumps the generated C++ for the entry file after a preamble.

pub fn get(a: i32) -> i32 { return a }
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --print-cxx | %FileCheck %s
// CHECK: CXX PREAMBLE fid {{[0-9]+}}: {{.*}}print_cxx.k
// CHECK: namespace print_cxx {
// CHECK: signed int get(signed int a) noexcept;
