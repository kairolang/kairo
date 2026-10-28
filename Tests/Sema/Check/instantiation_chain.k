// An instance that fails its bound two hops below the use that started it:
// `hop1<Metric>` reaches `hop2<Wrap<Metric>>`, which reaches
// `hop3<Wrap<Wrap<Metric>>>`, and `Wrap<Wrap<Metric>>` is not Named. The
// error is at the use (MONO.md D6), with one note per hop, innermost
// first, at the call in the body that needed the instance. `again` and
// the second `hop1` call need the same failing instance: it is reported
// once, at its first use, and they add nothing.

pub interface Scalable {
    fn scale(const self, factor: i32) -> i32
}
pub interface Named {
    fn name_len(const self) -> i32
}
pub struct Metric { pub var base: i32 }
extend Metric { pub fn scale(const self, factor: i32) -> i32 = self.base * factor }
pub struct <E> Wrap { pub var item: E }
extend <E> Wrap<E> { pub fn scale(const self, factor: i32) -> i32 = factor + 1 }
pub fn <T impl Named> hop3(a: T) -> i32 { return a.name_len() }
pub fn <T impl Scalable> hop2(a: T) -> i32 { return hop3(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop1(a: T) -> i32 { return hop2(Wrap<T> { item: a }) }
pub fn <T impl Scalable> again(a: T) -> i32 { return hop2(Wrap<T> { item: a }) }
fn main() -> i32 {
    var m = Metric { base: 3 }
    return hop1(m) + again(m) + hop1(m)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: instantiation_chain.k:25:12: error [SC001E]: 'Wrap<Wrap<Metric>>' does not conform to 'Named': no member 'name_len' with the requirement's signature
// CHECK-NEXT: instantiation_chain.k:19:9: note [I900N]: required by this bound
// CHECK-NEXT: instantiation_chain.k:13:5: note [I900N]: 'name_len' is required here
// CHECK-NEXT: instantiation_chain.k:20:53: note [I900N]: in instantiation of 'hop3<Wrap<Wrap<Metric>>>' required here
// CHECK-NEXT: instantiation_chain.k:21:53: note [I900N]: in instantiation of 'hop2<Wrap<Metric>>' required here
// CHECK-NOT: note
