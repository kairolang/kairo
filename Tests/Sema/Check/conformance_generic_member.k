// A generic record's own member meets a requirement at the INSTANCE's
// arguments: `Holder<i32>::get` returns T, which there is i32, so it meets
// `fn get(const self) -> i32`, exactly as a call `h.get()` on a
// Holder<i32> types as i32. The match used to compare the member's
// pattern-side `T` against i32 and report Holder<i32> as non-conforming
// (a generic EXTENSION's member was already read through its target).
// Holder<f64> still does not conform: T is f64 there.

interface Getter {
    fn get(const self) -> i32
}

class <T> Holder impl Getter {
    var v: T
    fn Holder(self, v: T) { self.v = v }
    fn get(const self) -> T { return self.v }
}

fn <G impl Getter> pick(g: G) -> i32 { return g.get() }

fn main() -> i32 {
    var a = pick(Holder<i32>(5))
    var b = pick(Holder<f64>(1.5))
    return a + b
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: conformance_generic_member.k:23:13: error [SC001E]: 'Holder<f64>' does not conform to 'Getter': no member 'get' with the requirement's signature
// CHECK-NOT: {{error|warning}}
