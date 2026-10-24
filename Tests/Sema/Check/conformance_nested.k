// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_nested.k:22:12: note [SC001N]: required by this call, in the instance of 'outer' used there
// CHECK: conformance_nested.k:25:12: error [SC001E]: 'Wrap<Metric>' does not conform to 'Named': no member 'name_len' with the requirement's signature
// CHECK: conformance_nested.k:20:9: note [I900N]: required by this bound
//
// An instance reached only through a generic's body: `outer<Metric>` calls
// `inner(Wrap<Metric>{...})`, and Wrap has no `name_len`. The error is at
// the outer use, the instantiation site, with a note at the call that
// asked for the failing instance.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub interface Named {
    fn name_len(const self) -> i32
}
pub struct Metric { pub var base: i32 }
extend Metric { pub fn scale(const self, factor: i32) -> i32 = self.base * factor }
pub struct <E> Wrap { pub var item: E }
pub fn <U impl Named> inner(a: U) -> i32 { return a.name_len() }
pub fn <T impl Scalable> outer(a: T) -> i32 {
    return inner(Wrap<T> { item: a }) + a.scale(1)
}
fn main() -> i32 {
    return outer(Metric { base: 3 })
}
