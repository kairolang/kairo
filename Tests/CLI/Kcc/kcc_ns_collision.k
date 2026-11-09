// C++ names a Kairo module whose name is a C global (`malloc.k`)
// through the documented rename, `malloc_::helper()`, and the C function
// `::malloc` is still the C function (Inputs/ns_collision). Exit 42 =
// helper's 40 + 2 for a successful ::malloc.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/ns_collision/use.cpp -o %t.d/app
// RUN: %t.d/app; test $? -eq 42
