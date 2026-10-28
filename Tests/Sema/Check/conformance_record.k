// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_record.k:{{[0-9]+}}:{{[0-9]+}}: error [SC001E]: 'Metric' does not conform to 'Scalable': no member 'scale' with the requirement's signature
// CHECK: conformance_record.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: required by this bound
// CHECK-NOT: does not conform
//
// A bounded record's instance is an instantiation site: `Box<Metric>`
// checks Metric against Box's bound wherever the type is named, with no
// generic function involved, and once per instance however many times it
// is named. Metric has no `scale`.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric { pub var base: i32 }
pub class <T impl Scalable> Box {
    pub var item: T
    fn Box(self, item: T) { self.item = item; }
}
fn main() -> i32 {
    var b = Box<Metric>(Metric { base: 3 })
    var c = Box<Metric>(Metric { base: 4 })
    return 0
}
