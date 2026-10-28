// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_operator_missing.k:24:12: error [SC001E]: 'W' does not conform to 'Growable': no member 'op +=' with the requirement's signature
// CHECK: conformance_operator_missing.k:18:9: note [I900N]: required by this bound
// CHECK: conformance_operator_missing.k:12:5: note [I900N]: 'op +=' is required here
//
// An OPERATOR requirement W does not meet: the diagnostic names it as
// `op +=`. An operator's name token is its operator token, which the
// identifier speller cannot read (it asserted in TokenText::resolve).
// W's `op +=` takes an i64, not the requirement's i32.

pub interface Growable {
    fn op +=(self, by: i32)
}
pub struct W { pub var v: i32 }
extend W {
    pub fn op +=(self, by: i64) { }
}
pub fn <T impl Growable> grow(a: T) -> T {
    var x = a
    x += 4
    return x
}
fn main() -> i32 {
    return grow(W { v: 3 }).v
}
