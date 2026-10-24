// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_qualified.k:16:12: error [SC001E]: 'i32' does not conform to 'Scalable': no member 'scale' with the requirement's signature
// CHECK: conformance_qualified.k:12:5: note [I900N]: 'scale' is required here
// CHECK-NOT: required by this bound
//
// `I::m(x)` on a concrete x is an instantiation site of its own: x must
// conform there, and there is no bound to point at. i32 has no `scale`.
//
//
//
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
fn main() -> i32 {
    var x: i32 = 3
    return Scalable::scale(x, 2)
}
