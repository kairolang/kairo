// An override of a C++ virtual whose return type differs, with no reference
// on either side: base `int val()`, override `-> i64`. Kairo accepted
// it and clang rejected the generated C++ (CL001E "virtual function 'val'
// has a different return type"). It is SC294E, with a fix-it to the C++
// declaration's type, as a reference return already was. A pointer
// to a derived record (`-> unsafe *D` over `B* self_()`) may be a covariant
// return, legal in C++: left to clang, and accepted here (good.k builds and
// runs). An override with no `->` over a `void` virtual is fine.

ffi "c++" import "b.h"

class D derives B {
    override fn val(self) -> i64 { return 2 }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -I %S/Inputs/override_return_mismatch %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: override_return_mismatch_plain.k:13:30: error [SC294E]: 'val' returns 'i64', but the C++ virtual it overrides returns 'i32'
// CHECK-NEXT: fix-it:"{{.*}}override_return_mismatch_plain.k":{13:30-13:33}:"i32"
// CHECK-NEXT: b.h:2:5: note [SC294N]: the C++ virtual it overrides, whose return it must match
// RUN: rm -rf %t.d
// RUN: { %kairo -I %S/Inputs/override_return_mismatch %S/Inputs/override_return_mismatch/good.k -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=GOOD --allow-empty
// GOOD-NOT: error
// RUN: %t.exe
