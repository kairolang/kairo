// witness/static.k -- exit 8
// A STATIC requirement through a bound, `T::make()`: `static __kairo_Self
// make()` in the witness, called as `::N::Makeable_witness<T>::make()`
// (CODEGEN.md §7b.3, §7b.5).
//
// XFAIL: *
// Waiting on two pieces. The typer does not read `-> Self` back through a
// `::` step, so `t` is untyped (I011W) and `t.value()` reaches codegen
// unbound; and ExtensionLowering rewrites only `a.m()` / `p->m()` calls, so
// `T::make()` is the EmitIR ICE naming it. When both land this XPASSes:
// drop the XFAIL, the run below is already the real assertion.
pub interface Makeable {
    static fn make() -> Self
    fn value(const self) -> i32
}
pub struct Seven {
    pub var v: i32
}
extend Seven {
    pub static fn make() -> Seven = Seven { v: 7 }
    pub fn value(const self) -> i32 = self.v
}
pub fn <T impl Makeable> build(seed: T) -> i32 {
    var t = T::make()
    return t.value() + seed.value()
}
fn main() -> i32 {
    return build(Seven { v: 1 })
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
