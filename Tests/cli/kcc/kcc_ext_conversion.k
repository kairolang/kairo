// An `op as` declared in an extension, across the C++ boundary. Kairo
// applies the conversion itself and writes the call out, so the Kairo
// function that relies on it works when a C++ host calls it (9 feet is 3
// meters). The host is given no conversion: `Feet` is not convertible to
// `Meters` in C++, which the host asserts.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -c %S/inputs/ext_conversion/host.cc -o %t.d/host.o
// RUN: %kcc -c %S/inputs/ext_conversion/units.k -o %t.d/units.o
// RUN: %kcc %t.d/host.o %t.d/units.o -o %t.d/main
// RUN: %t.d/main; test $? -eq 3
