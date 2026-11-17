// A member that comes from an `extend` with bounds exists for an instance
// only when the bounds hold for its arguments. When the bounds of every
// candidate fail, the call has no viable candidate and each note names the
// bound that fails; one candidate whose bound fails is SC162E at the use.

interface Small {
    fn small(const self) -> i32
}

interface Big {
    fn big(const self) -> i32
}

class A {
    pub fn A(self) { }
}

class B {
    pub fn B(self) { }
}

extend A impl Small {
    fn small(const self) -> i32 = 1
}

class <T> Box {
    pub var v: T
}

class <T> Crate {
    pub var v: T
}

extend <T impl Small> Box<T> impl Small {
    fn small(const self) -> i32 = self.v.small()
}

extend <T> Crate<T> impl Small requires T impl Small {
    fn small(const self) -> i32 = self.v.small()
}

fn <T> pick(const x: T) -> i32 requires T impl Small {
    return 20
}

fn <T> pick(const x: T) -> i32 requires !(T impl Small) {
    return 10
}

extend <T> Box<T> {
    pub fn <C> choose(self) -> i32 = 10
}

extend <T impl Small> Box<T> {
    pub fn <C> choose(self) -> i32 = 20
}

extend <T impl Small> Crate<T> {
    pub fn only(self) -> i32 = 1
}

extend <T impl Big> Crate<T> {
    pub fn only(self) -> i32 = 2
}

fn neither() -> i32 {
    var cb = Crate<B> { v: B() }
    return cb.only()
}

fn one() -> i32 {
    var b = Box<B> { v: B() }
    return b.small()
}

fn main() -> i32 = 0

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT:  error
// CHECK:      :68:12: error [SC063E]: no matching overload for call to 'only'
// CHECK-NEXT: :59:9: note [I900N]: candidate not viable: the bound of its extension does not hold: 'B' does not implement 'Small': it has no 'small'
// CHECK-NEXT: :63:9: note [I900N]: candidate not viable: the bound of its extension does not hold: 'B' does not implement 'Big': it has no 'big'
// CHECK-NOT:  error
// CHECK:      :73:12: error [SC162E]: 'B' does not conform to 'Small': no member 'small' with the requirement's signature
// CHECK-NOT:  error [
