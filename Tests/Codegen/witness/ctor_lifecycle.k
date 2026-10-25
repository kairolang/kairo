// witness/ctor_lifecycle.k -- exit 31
// A lifecycle constructor requirement's concept clause forwards its
// argument (`static_cast<decltype(a0)&&>(a0)`), so `@move`'s by-value
// `other: Self` asks C++ for a move constructor and a move-only conformer
// satisfies the concept on the template head; `@copy`'s `const Self&`
// asks for a copy. No witness member exists for either.
interface Copyable {
    @copy
    fn Copyable(self, const other: Self)
}
interface Movable {
    @move
    fn Movable(self, other: Self)
}
pub struct P { pub var n: i32 = 1 }
pub class C {
    pub var n: i32 = 2
    fn C(self) { }
    @copy fn C(self, const other: C) { self.n = other.n }
}
@move
pub class M {
    pub var n: i32 = 4
    fn M(self) { }
    @move fn M(self, other: M) { self.n = other.n }
}
fn <T impl Copyable> store(item: T) -> T { return item }
fn <T impl Movable> take(item: T) -> T { return item }
fn main() -> i32 { return store(P()).n + store(C()).n + store(8) + take(M()).n + take(16) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/ctor_lifecycle.k
// CXX: concept Copyable_c = requires(const __kairo_Self & __kairo_a0) {
// CXX-NEXT: __kairo_Self(static_cast<decltype(__kairo_a0) &&>(__kairo_a0));
// CXX-NEXT: };
// CXX: concept Movable_c = requires(__kairo_Self __kairo_a0) {
// CXX-NEXT: __kairo_Self(static_cast<decltype(__kairo_a0) &&>(__kairo_a0));
// CXX-NEXT: };
// CXX: struct Copyable_witness {
// CXX-NEXT: };
// CXX: struct Movable_witness {
// CXX-NEXT: };
// CXX-NOT: template<> struct {{(Copyable|Movable)}}_witness

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
