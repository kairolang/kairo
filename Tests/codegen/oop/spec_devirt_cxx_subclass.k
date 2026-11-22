// C++ classes derived from Kairo classes still dispatch correctly through
// calls that speculative devirtualization versioned (spec_devirt.k), under
// both compares: a C++ override, a C++ override of a Kairo override, and C++
// subclasses that inherit a Kairo body. Under vptr compares (area_of) every
// C++ class takes the indirect fallback; under slot compares (level_of) a C++
// class that inherits Meter's body runs the direct arm.
// inputs/spec_devirt_cxx/shapes.k is built as a library object (no main)
// whose classes a C++ file includes and derives.
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// RUN: rm -rf %t.d && mkdir -p %t.d

// The library object's code compares the vptr with the vtables of Rect,
// Square and Shape, and keeps the indirect call through the slot.
// RUN: %kairo -I %S/inputs/spec_devirt_cxx -c %S/inputs/spec_devirt_cxx/shapes.k -O2 --emit=llvm-ir --cache-dir %t.d/ir
// RUN: %FileCheck %s --check-prefix=IR < %t.d/ir/shapes.ll
// IR-LABEL: define {{.*}}@_ZN6shapes7area_ofEPKNS_5ShapeE(
// IR:       %[[VP:vtable[0-9a-z.]*]] = load ptr, ptr %s
// IR-DAG:   icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN6shapes4RectE, i64 16)
// IR-DAG:   icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN6shapes6SquareE, i64 16)
// IR:       icmp eq ptr %[[VP]], getelementptr inbounds {{.*}}(i8, ptr @_ZTVN6shapes5ShapeE, i64 16)
// IR:       %[[FN:[0-9a-z.]+]] = load ptr, ptr %[[VP]],
// IR-NEXT:  call {{.*}}i64 %[[FN]](ptr
// IR:       {{^}}}

// level_of's call compares the loaded slot with Meter's body, then Gauge's.
// RUN: %FileCheck %s --check-prefix=SLOT < %t.d/ir/shapes.ll
// SLOT-LABEL: define {{.*}}@_ZN6shapes8level_ofEPKNS_5GaugeE(
// SLOT:       %[[SL:[0-9a-z.]+]] = load ptr, ptr %vtable{{[0-9a-z.]*}},
// SLOT:       icmp eq ptr %[[SL]], @_ZNK6shapes5Meter5levelEv
// SLOT:       icmp eq ptr %[[SL]], @_ZNK6shapes5Gauge5levelEv
// SLOT:       call {{.*}}i64 %[[SL]](ptr
// SLOT:       {{^}}}

// The program, at the same level: 600 and 7000 from C++, 1 from the base
// body Plain inherits, 10 and 16 from the Kairo overrides; then 30 from
// Meter's body through an arm (a C++ PlainMeter and a Kairo M1), 400 from
// C++ through the fallback, and 2 from Gauge's own body.
// RUN: rm -f %t.d/app
// RUN: %kairo -O2 -I %S/inputs/spec_devirt_cxx %S/inputs/spec_devirt_cxx/main.cc %S/inputs/spec_devirt_cxx/shapes.k -o %t.d/app --cache-dir %t.d/obj
// RUN: %t.d/app | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      600 7000 1 10 16
// OUT-NEXT: 30 400 30 2
