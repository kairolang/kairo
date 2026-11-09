// `(unsafe &self) as unsafe *T` in a CRTP mixin that is NOT the first
// base. The cast is dependent (T per instance), so CastTyping sees no
// base_adjust; a reinterpret_cast then misses the mixin's offset in the
// instance and `self.dyn()->x` reads garbage. A C-style cast is static_cast
// where the instance's classes are related. Both mixins must read 55.
class <T: type> MixA {
    pub var a: i32 = 1
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn from_a(self) -> i32 { return self.dyn()->x; }
}
class <T: type> MixB {
    pub var b: i32 = 2
    priv inline fn dyn(self) -> unsafe *T { return unsafe ((unsafe &self) as unsafe *T); }
    fn from_b(self) -> i32 { return self.dyn()->x; }
}
class Host derives MixA<Host>, MixB<Host> {
    pub var x: i32 = 55
}
fn main() -> i32 {
    var h: Host;
    return h.from_a() + h.from_b() - 55;
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe; test $? -eq 55
// DIAG-NOT: C871W
// DIAG-NOT: error
