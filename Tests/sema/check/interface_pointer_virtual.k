// Only a `virtual interface` has a pointer (interfaces.mdx, Virtual
// Interfaces), and dispatch through one is not compiled yet (SC116E). A
// plain interface has none: `*Shape` is SC332E, as `Shape` is.

interface Shape {
    fn area(const self) -> i32
}

virtual interface Heap {
    fn free(self, size: usize)
}

fn plain(p: *Shape) -> i32 { return 0 }
fn dispatched(h: *Heap) -> i32 { return 0 }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: interface_pointer_virtual.k:13:13: error [SC332E]: 'Shape' is an interface, not a type, and a plain interface has no pointer; bound a generic parameter (`T impl Shape`), or declare it `virtual interface` for dispatch through a pointer
// CHECK: interface_pointer_virtual.k:14:18: error [SC116E]: a pointer to the interface 'Heap' (virtual interface dispatch) is not yet supported
// CHECK-NOT: error
