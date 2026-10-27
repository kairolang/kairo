// `where` dispatch from a C++ host (Inputs/where_host: guards.k,
// where_main.cpp): each group is ONE C++ function under its public name,
// so the host calls `guards::categorize` and a method group's `read` like
// any other function and gets the guard dispatch Kairo callers get. The
// candidates are private: a free group's are not declared to the host, and
// a method group's are private members (the host checks both).
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc -std=c++20 %S/Inputs/where_host/where_main.cpp -o %t.d/app 2>/dev/null
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// CHECK:      categorize 2 1 0
// CHECK-NEXT: divide 5 0
// CHECK-NEXT: read 3 10
// CHECK-EMPTY:
