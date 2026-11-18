// SC297E (an override's return disagrees with the Kairo virtual it
// overrides) had a fix-it only when both sides return a value. A value
// over a `void` virtual gets the `-> T` removed, and an override with
// no `->` over a value gets one inserted, after the parameters or after a
// `panic` specifier, which comes first (panic.mdx).

class E {
    fn E(self) {}
    fn op panic(const self) -> string { return "e" }
}

class KB {
    fn KB(self) {}
    virtual fn a(self) { }
    virtual fn b(self) -> i32 { return 1 }
    virtual fn c(self) panic(E) -> i32 { return 1 }
}

class KD derives KB {
    fn KD(self) {}
    fn a(self) -> i32 { return 2 }
    fn b(self) { }
    fn c(self) panic(E) { }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: override_return_void_fixits.k:21:19: error [SC297E]: 'a' returns 'i32', but the virtual it overrides returns 'void'
// CHECK-NEXT: fix-it:"{{.*}}":{21:15-21:22}:""
// CHECK: override_return_void_fixits.k:22:8: error [SC297E]: 'b' returns 'void', but the virtual it overrides returns 'i32'
// CHECK-NEXT: fix-it:"{{.*}}":{22:15-22:15}:" -> i32"
// CHECK: override_return_void_fixits.k:23:8: error [SC297E]: 'c' returns 'void', but the virtual it overrides returns 'i32'
// CHECK-NEXT: fix-it:"{{.*}}":{23:24-23:24}:" -> i32"
