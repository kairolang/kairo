// witness/generic_iface.k -- exit 5
// A generic interface keys its witness on `<Self, A...>`: the bound names
// the interface's argument (`T impl Container<U>`), the concept and the call
// spell it, and Bag's row is the specialization at `<Bag, i32>`
// (CODEGEN.md §7b.3, "Generic interfaces").
pub interface <E> Container {
    fn get(const self, i: i32) -> E
}
pub struct Bag {
    pub var base: i32
}
extend Bag {
    pub fn get(const self, i: i32) -> i32 = self.base + i
}
pub fn <T, U> first(c: T, seed: U) -> U requires T impl Container<U> {
    return c.get(1)       // `seed` only deduces U: an unbounded U has no `+`
}
fn main() -> i32 {
    var b = Bag { base: 4 }
    return first(b, 2)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/generic_iface.k
// CXX: template<class __kairo_Self, class E> struct Container_witness;
// CXX: template<class __kairo_Self, class E> concept Container_c =
// CXX-NEXT: Container_witness<__kairo_Self, E>::get(__kairo_r0, __kairo_a0);
// CXX: template<> struct Container_witness<{{ ?}}::{{.*}}::Bag, signed int> {
// CXX: requires{{ ?}}({{ ?}}::{{.*}}::Container_c<T, U>) U first(T c, U seed) noexcept;
// CXX: Container_witness<T, U>::get((& c), 1)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
