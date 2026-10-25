// witness/composed_generic_leaf.k -- exit 5
// A composition over a CONCRETE generic interface instance: IntBox derives
// Container<i32> + Sized. The inherited `get` returns Container's E, which
// the witness spells at the leaf's arguments (signed int), as a
// specialization's members are spelled. (A DEPENDENT leaf, `interface <T> F
// derives Container<T>`, is not compiled yet.)
pub interface <E> Container { fn get(const self) -> E }
pub interface Sized { fn size(const self) -> i32 }
pub interface IntBox derives Container<i32> + Sized { }
pub struct B { pub var v: i32 }
extend B {
    pub fn get(const self) -> i32 = self.v
    pub fn size(const self) -> i32 = 1
}
pub fn <T impl IntBox> f(x: T) -> i32 = x.get() + x.size()
fn main() -> i32 { return f(B { v: 4 }) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/composed_generic_leaf.k
// CXX: concept IntBox_c = requires(const __kairo_Self * __kairo_r0, const __kairo_Self * __kairo_r1) {
// CXX: static signed int get(const __kairo_Self * self) requires requires {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
