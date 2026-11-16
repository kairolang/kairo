// A C++ host sees a Kairo byte string as the slice it is (Inputs/
// byte_string_host: bytelit.k, bytes_main.cpp): a pointer to the literal's
// static bytes and their count, with no terminator counted and the same
// address on every call.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/byte_string_host/bytes_main.cpp -o %t.d/app
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      len 6, first 127, last 255
// CHECK-NEXT: static 1
// CHECK-NEXT: total 6 597
// CHECK-EMPTY:
