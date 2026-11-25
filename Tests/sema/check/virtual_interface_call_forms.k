// Every receiver form of a call through `*Iface` reaches FeatureGateCheck's
// SC116E, never ExtensionLowering's "witness Self must be dependent"
// internal error: a field, a dereference, a call result, a loop variable and
// a closure capture. A full build runs, so lowering would be reached if the
// gate missed a form.
virtual interface Heap {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8
    fn free(self, ptr: unsafe *u8, size: usize)
}

class LibcHeap impl Heap {
    fn alloc(self, size: usize, align: usize) -> unsafe *u8 { return &null }
    fn free(self, ptr: unsafe *u8, size: usize) { }
}

class Owner {
    pub var heap: *Heap
    fn Owner(self, h: *Heap) { self.heap = h }
    fn give_back(self, p: unsafe *u8) { self.heap->free(p, 1) }
}

fn pick(h: *Heap) -> *Heap { return h }

fn forms(h: *Heap, hs: [*Heap]) {
    (*h).free(&null, 0)
    pick(h)->free(&null, 0)
    for x in hs {
        x->free(&null, 0)
    }

    var f = fn () { h->free(&null, 0) }
    f()
}

fn main() -> i32 {
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: virtual_interface_call_forms.k:19:50: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// CHECK: virtual_interface_call_forms.k:25:9: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// CHECK: virtual_interface_call_forms.k:26:12: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// CHECK: virtual_interface_call_forms.k:28:10: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// CHECK: virtual_interface_call_forms.k:31:22: error [SC116E]: a call through an interface pointer (virtual interface dispatch) is not yet supported
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=NOICE
// NOICE-NOT: Internal Compiler Error
// NOICE-NOT: witness Self must be dependent
// NOICE: error [SC116E]
// NOICE-NOT: Internal Compiler Error
// NOICE-NOT: witness Self must be dependent
