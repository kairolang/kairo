// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_dependent_leaf.k:29:19: error [SC001E]: 'Bad' does not conform to 'Fancy<i32>': no member 'get' with the requirement's signature
// CHECK: conformance_dependent_leaf.k:25:9: note [I900N]: required by this bound
// CHECK: conformance_dependent_leaf.k:13:31: note [I900N]: 'get' is required here
// CHECK-NOT: error
//
// A requirement inherited through a DEPENDENT instance (Fancy<T> derives
// Container<T>) is matched at the bound's arguments: Container's E is
// Fancy's T is i32, so Good's `get -> i32` meets it and Bad's `get -> Q`
// does not.

pub struct Q { pub var v: i32 }
pub interface <E> Container { fn get(const self, i: i32) -> E }
pub interface <T> Fancy derives Container<T> { fn shine(const self) -> T }
pub struct Good { pub var v: i32 }
extend Good {
    pub fn get(const self, i: i32) -> i32 = i
    pub fn shine(const self) -> i32 = 1
}
pub struct Bad { pub var v: i32 }
extend Bad {
    pub fn get(const self, i: i32) -> Q = Q { v: i }
    pub fn shine(const self) -> i32 = 1
}
pub fn <C impl Fancy<i32>> g(c: C) -> i32 { return c.shine() }
fn main() -> i32 {
    var a = Good { v: 0 }
    var b = Bad { v: 0 }
    return g(a) + g(b)
}
