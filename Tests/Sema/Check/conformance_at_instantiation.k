// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_at_instantiation.k:25:12: error [SC001E]: 'Metric' does not conform to 'Scalable': no member 'scale' with the requirement's signature
// CHECK: conformance_at_instantiation.k:20:9: note [I900N]: required by this bound
// CHECK: conformance_at_instantiation.k:12:5: note [I900N]: 'scale' is required here
//
// A generic's `T impl I` bound is checked where it meets a concrete
// argument: Metric's `scale` takes an i64, not the requirement's i32, so it
// is no witness and the call is the user's error, not clang's (RESOLUTION.md
// §2b, "The conformance table").

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i64) -> i32 = 1
}
pub fn <T impl Scalable> twice(a: T) -> i32 {
    return a.scale(2)
}
fn main() -> i32 {
    var m = Metric { base: 3 }
    return twice(m)
}
