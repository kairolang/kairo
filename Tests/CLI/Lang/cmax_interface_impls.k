// --cmax-interface-impls errors on a class listing more `impl` interfaces
// than the limit; 0 is unlimited. Two interfaces: a limit of 2 accepts, 1
// rejects.

interface A { fn a(self) }
interface B { fn b(self) }

class C impl A, B {
    fn C(self) { }
    fn a(self) { }
    fn b(self) { }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-interface-impls=2 %s
// RUN: %kairo --type-check-only --cmax-interface-impls=0 %s
// RUN: { %kairo --type-check-only --cmax-interface-impls=1 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_interface_impls.k:8:{{[0-9]+}}: error [SC001E]: class implements too many interfaces (2, limit 1)
