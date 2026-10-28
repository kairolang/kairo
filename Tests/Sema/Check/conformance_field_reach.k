// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_field_reach.k:20:12: error [SC001E]: 'Metric' does not conform to 'Named': no member 'name_len' with the requirement's signature
// CHECK: conformance_field_reach.k:16:13: note [I900N]: required by this bound
// CHECK-NOT: error
//
// `Box<Metric>` is named nowhere: `Outer<Metric>` has a `Box<T>` field, so
// instantiating it instantiates `Box<Metric>` too. The discovery fixpoint
// walks a record instance's fields as well as its methods, and the reached
// instance, which has no range of its own, is reported at the use of the
// instance that reached it. It used to pass unreported, leaving clang's
// concept to reject the C++.

pub interface Named {
    fn name_len(const self) -> i32
}
pub struct <T impl Named> Box { pub var item: T }
pub struct Metric { pub var base: i32 }
pub struct <T> Outer { pub var b: Box<T> }
fn main() -> i32 {
    var p: *Outer<Metric> = &null
    return 0
}
