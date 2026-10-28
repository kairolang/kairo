// A failure seven hops below its use: `hop8<Wrap^7<Metric>>` is not
// Named. The chain notes are capped at --cmax-generic-backtrace (5): the
// innermost three, a note counting the hops left out, the outermost two
// (MONO.md D6). The flag at 0 shows every hop.

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
pub fn <T impl Named> hop8(a: T) -> i32 { return a.name_len() }
pub fn <T impl Scalable> hop7(a: T) -> i32 { return hop8(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop6(a: T) -> i32 { return hop7(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop5(a: T) -> i32 { return hop6(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop4(a: T) -> i32 { return hop5(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop3(a: T) -> i32 { return hop4(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop2(a: T) -> i32 { return hop3(Wrap<T> { item: a }) }
pub fn <T impl Scalable> hop1(a: T) -> i32 { return hop2(Wrap<T> { item: a }) }
fn main() -> i32 {
    return hop1(Metric { base: 3 })
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=CAP --implicit-check-not="error ["
// CAP: instantiation_chain_long.k:25:12: error [SC001E]: 'Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Metric>>>>>>>' does not conform to 'Named'
// CAP-NEXT: instantiation_chain_long.k:16:9: note [I900N]: required by this bound
// CAP-NEXT: instantiation_chain_long.k:10:5: note [I900N]: 'name_len' is required here
// CAP-NEXT: instantiation_chain_long.k:17:53: note [I900N]: in instantiation of 'hop8<Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Metric>>>>>>>>' required here
// CAP-NEXT: instantiation_chain_long.k:18:53: note [I900N]: in instantiation of 'hop7<Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Metric>>>>>>>' required here
// CAP-NEXT: instantiation_chain_long.k:19:53: note [I900N]: in instantiation of 'hop6<Wrap<Wrap<Wrap<Wrap<Wrap<Metric>>>>>>' required here
// CAP-NEXT: note [I900N]: 2 more instantiations in the chain; --cmax-generic-backtrace=0 shows them all
// CAP-NEXT: instantiation_chain_long.k:22:53: note [I900N]: in instantiation of 'hop3<Wrap<Wrap<Metric>>>' required here
// CAP-NEXT: instantiation_chain_long.k:23:53: note [I900N]: in instantiation of 'hop2<Wrap<Metric>>' required here
// CAP-NOT: note

// RUN: { %kairo %s --type-check-only --cmax-generic-backtrace=0 2>&1 || true; } | %FileCheck %s --check-prefix=ALL --implicit-check-not="error ["
// ALL: instantiation_chain_long.k:25:12: error [SC001E]: 'Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Wrap<Metric>>>>>>>' does not conform to 'Named'
// ALL: instantiation_chain_long.k:17:53: note [I900N]: in instantiation of 'hop8<
// ALL-NEXT: instantiation_chain_long.k:18:53: note [I900N]: in instantiation of 'hop7<
// ALL-NEXT: instantiation_chain_long.k:19:53: note [I900N]: in instantiation of 'hop6<
// ALL-NEXT: instantiation_chain_long.k:20:53: note [I900N]: in instantiation of 'hop5<
// ALL-NEXT: instantiation_chain_long.k:21:53: note [I900N]: in instantiation of 'hop4<
// ALL-NEXT: instantiation_chain_long.k:22:53: note [I900N]: in instantiation of 'hop3<
// ALL-NEXT: instantiation_chain_long.k:23:53: note [I900N]: in instantiation of 'hop2<
// ALL-NOT: more instantiations
