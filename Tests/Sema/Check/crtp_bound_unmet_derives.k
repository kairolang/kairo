// A bound that names the generic record's own derived class (CRTP) is
// checked by Kairo where the class derives the record, as for any other
// bound: `class NoImpl derives Mixin<NoImpl>` without the `impl Impl`
// member is SC162E at the `derives` clause, with a note on the bound. The
// class that satisfies it (Seven) is clean, and nothing reaches the C++
// compiler.

interface Impl {
    fn value(const self) -> i32
}

class <X derives Mixin<X> impl Impl> Mixin {
    fn doubled(const self) -> i32 {
        unsafe {
            var d = &self as unsafe *const X
            return d->value() * 2
        }
    }
}

class NoImpl derives Mixin<NoImpl> {
    fn other(const self) -> i32 { return 1 }
}

class Seven derives Mixin<Seven> impl Impl {
    fn value(const self) -> i32 { return 7 }
}

fn main() -> i32 {
    var s = Seven()
    return s.doubled()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: crtp_bound_unmet_derives.k:21:22: error [SC162E]: 'NoImpl' does not conform to 'Impl': no member 'value' with the requirement's signature
// CHECK: crtp_bound_unmet_derives.k:12:8: note [I900N]: required by this bound
