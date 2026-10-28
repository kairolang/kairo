// Sema/Check/conformance_ctor.k
// A CONSTRUCTOR requirement -- a method named after its interface -- is
// met by the conformer's own constructor, named after the conformer, so a
// lookup by the requirement's name never finds it. The match is the
// constructor's parameters against the requirement's, Self replaced by
// the conformer; a record that declares no constructor has the implicit
// `X()`, and a builtin has none at all (`i32()` is SC037E, not a call).
pub interface Defaultable { fn Defaultable(self) }
pub interface Sized { fn Sized(self, n: i32) }
pub interface Twin { fn Twin(self, other: Self, k: i32) }
pub class Counter {
    pub var n: i32 = 0
    fn Counter(self) { }
    fn Counter(self, n: i32) { self.n = n }
    fn Counter(self, other: Counter, k: i32) { self.n = other.n + k }
}
pub class Flag {
    fn Flag(self, b: bool) { }
}
pub struct Plain { pub var n: i32 = 7 }
pub class Base { fn Base(self, n: i32) { } }
pub class Kid derives Base { fn Kid(self) { } }
pub class <E> Box { fn Box(self, e: E) { } }
pub fn <T impl Defaultable> fresh(like: T) -> T { return T() }
pub fn <T impl Sized> sized(like: T, n: i32) -> T { return T(n) }
pub fn <T impl Twin> twin(a: T) -> T { return T(a, 5) }
fn main() -> i32 {
    var ok1 = fresh(Counter())
    var ok2 = sized(Counter(), 3)
    var ok3 = twin(Counter())
    var ok4 = fresh(Plain())
    var ok5 = sized(Box<i32>(1), 2)
    var no1 = fresh(Flag(true))
    var no2 = sized(Flag(true), 3)
    var no3 = fresh(1)
    var no4 = sized(Plain(), 2)
    var no5 = sized(Kid(), 2)
    var no6 = sized(Box<bool>(true), 2)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// Accepted: an own constructor of the requirement's arity and types, Self
// as the conformer, the implicit default, a generic record's constructor
// at the instance's arguments. Rejected, each naming the constructor that
// is missing: wrong parameter types, a builtin, a record whose only
// constructor is the implicit default, a BASE's constructor (not the
// conformer's), a generic record at the wrong argument.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: conformance_ctor.k:{{(28|29|30|31|32)}}:
// CHECK: conformance_ctor.k:33:15: error [SC001E]: 'Flag' does not conform to 'Defaultable': no constructor 'Flag()'
// CHECK: conformance_ctor.k:24:9: note [I900N]: required by this bound
// CHECK: conformance_ctor.k:8:29: note [I900N]: the constructor is required here
// CHECK: conformance_ctor.k:34:15: error [SC001E]: 'Flag' does not conform to 'Sized': no constructor 'Flag(i32)'
// CHECK: conformance_ctor.k:35:15: error [SC001E]: 'i32' does not conform to 'Defaultable': no constructor 'i32()'
// CHECK: conformance_ctor.k:36:15: error [SC001E]: 'Plain' does not conform to 'Sized': no constructor 'Plain(i32)'
// CHECK: conformance_ctor.k:37:15: error [SC001E]: 'Kid' does not conform to 'Sized': no constructor 'Kid(i32)'
// CHECK: conformance_ctor.k:38:15: error [SC001E]: 'Box<bool>' does not conform to 'Sized': no constructor 'Box<bool>(i32)'
// CHECK-NOT: error
