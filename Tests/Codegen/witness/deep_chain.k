// witness/deep_chain.k -- exit 2
// A chain of twelve generics, each calling the next with its argument
// wrapped once more: `hopl<Wrap^11<Metric>>` is reached only through eleven
// bodies. Each instance on the way binds `(Wrap^k<Metric>, Scalable)`, and
// every plan holding the outer instance follows the reach to the end, so
// every row's witness specialization is written. The reach used to stop
// silently at depth 8, leaving the rest to clang's concept, which rejected
// the call; the discovery fixpoint goes to --cmax-generic-depth (128).
pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub struct Metric {
    pub var base: i32
}
extend Metric {
    pub fn scale(const self, factor: i32) -> i32 = self.base * factor
}
pub struct <E> Wrap {
    pub var item: E
}
extend <E> Wrap<E> {
    pub fn scale(const self, factor: i32) -> i32 = factor + 1
}
pub fn <T impl Scalable> hopl(a: T) -> i32 { return a.scale(1) }
pub fn <T impl Scalable> hopk(a: T) -> i32 { return hopl(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopj(a: T) -> i32 { return hopk(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopi(a: T) -> i32 { return hopj(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hoph(a: T) -> i32 { return hopi(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopg(a: T) -> i32 { return hoph(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopf(a: T) -> i32 { return hopg(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hope(a: T) -> i32 { return hopf(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopd(a: T) -> i32 { return hope(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopc(a: T) -> i32 { return hopd(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopb(a: T) -> i32 { return hopc(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hopa(a: T) -> i32 { return hopb(Wrap<T> { item: a }) }
fn main() -> i32 {
    return hopa(Metric { base: 3 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/deep_chain.k
// CXX: template<> struct Scalable_witness<{{( ?::[A-Za-z_:]*::Wrap<){11} ?::[A-Za-z_:]*::Metric}}>>>>>>>>>>>> {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2
