// A requirement called through `*Iface` is virtual interface dispatch,
// which has no lowering yet. ExtensionLowering renders requirement calls only
// through a dependent Self (a "witness Self must be
// dependent" internal error otherwise); FeatureGateCheck reports it as not yet supported.
virtual interface Heap {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8
    fn free(self, ptr: unsafe *u8, size: usize)
}

class LibcHeap impl Heap {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8 { return &null }
    fn free(self, ptr: unsafe *u8, size: usize) { }
}

fn release(heap: *Heap, ptr: unsafe *u8, size: usize) {
    heap->free(ptr, size)
}

// A bound on the same interface is an ordinary static call, never gated.
fn <T impl Heap> release_static(heap: *T, ptr: unsafe *u8, size: usize) {
    heap->free(ptr, size)
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: virtual_interface_call_gate.k:16:9: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// CHECK-NOT: error
// CHECK-NOT: Internal Compiler Error
