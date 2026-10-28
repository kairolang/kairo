// The user's report (Inputs/ctor_field_init): a Kairo class whose array
// field holds an enum with payloads, which has no default, built from C++.
// packet.k gives the field a list-literal initializer and then writes its
// elements in the constructor; packet_whole.k gives it none and builds it
// whole in the constructor, the write that is its C++ mem-initializer
// (CtorInitCheck). Both compile through kcc, run, and destroy the object
// once when C++ scope ends.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: kcc, default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d && cd %t.d
// RUN: %kcc %S/Inputs/ctor_field_init/main.cpp -o %t.d/app 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// RUN: %t.d/app | %FileCheck %s --match-full-lines
// RUN: %kcc %S/Inputs/ctor_field_init/main_whole.cpp -o %t.d/app_whole 2>&1 | %FileCheck %s --check-prefix=QUIET --allow-empty
// RUN: %t.d/app_whole | %FileCheck %s --match-full-lines
// QUIET-NOT: {{error|warning}}
// CHECK:      [C++] Total = 344
// CHECK-NEXT: [Kairo] Batch::~Batch() RAII dtor fired from C++ scope!
// CHECK-EMPTY:
