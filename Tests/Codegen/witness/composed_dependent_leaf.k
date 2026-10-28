// witness/composed_dependent_leaf.k -- exit 28
// A composition over a DEPENDENT generic interface instance: Fancy<T>
// derives Container<T>, so the inherited `get` returns Container's E, which
// is Fancy's T. The primary spells it in Fancy's own parameter (the text is
// inside Fancy_witness's template); a specialization spells it at the row's
// arguments, Container's E -> Fancy's T -> the row's argument, composed.
// Deep<U> derives Fancy<U> composes twice; Wrapped<V> derives
// Container<Wrap<V>> substitutes inside a record argument; h's bound is
// Fancy<E> over its own parameter.
pub interface <E> Container { fn get(const self, i: i32) -> E }
pub interface <T> Fancy derives Container<T> { fn shine(const self) -> T }
pub interface <U> Deep derives Fancy<U> { fn dig(const self) -> U }
pub struct <W> Wrap { pub var w: W }
pub interface <V> Wrapped derives Container<Wrap<V>> { fn raw(const self) -> V }

// Own members: the primary serves the row.
pub class Box impl Fancy<i32> {
    fn Box(self) { }
    fn get(const self, i: i32) -> i32 = i + 1
    fn shine(const self) -> i32 = 5
}
// Extension members: a specialization, spelled at i64 through two leaves.
pub struct Ext { pub var v: i64 }
extend Ext impl Deep<i64> {
    pub fn get(const self, i: i32) -> i64 = self.v + i
    pub fn shine(const self) -> i64 = 10
    pub fn dig(const self) -> i64 = 100
}
pub struct WB { pub var v: i32 }
extend WB {
    pub fn get(const self, i: i32) -> Wrap<i32> = Wrap<i32> { w: self.v + i }
    pub fn raw(const self) -> i32 = self.v
}

pub fn <C impl Fancy<i32>> g(c: C) -> i32 { return c.get(1) + c.shine() }
pub fn <C impl Deep<i64>> d(c: C) -> i64 { return c.get(1) + c.shine() + c.dig() }
// The typed temporary is the form that worked before a bound call's result
// was typed at the bound's arguments; witness/bound_call_member.k has the
// direct `c.get(1).w`.
pub fn <C impl Wrapped<i32>> w(c: C) -> i32 { var r: Wrap<i32> = c.get(1); return r.w + c.raw() }
// (`z` is only deduced from: an unbounded E has no `+`, MONO.md D0.)
pub fn <E, C impl Fancy<E>> h(c: C, z: E) -> E { return c.get(2) }

fn main() -> i32 {
    var b = Box()
    var e = Ext { v: 1000 }
    var x = WB { v: 3 }
    var r = g(b) + w(x) + h(b, 0)    // 7 + 7 + 3
    if d(e) == 1111 { r += 11 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/composed_dependent_leaf.k
// CXX-NOT: internal compiler error
// CXX: template<class __kairo_Self, class T> struct Fancy_witness {
// CXX-NEXT: static T get(const __kairo_Self * self, signed int i) requires requires {
// CXX-NEXT: static_cast<T(__kairo_Self::*)(signed int) const>(& __kairo_Self::get);
// CXX: template<class __kairo_Self, class U> struct Deep_witness {
// CXX-NEXT: static U get(const __kairo_Self * self, signed int i) requires requires {
// CXX: template<class __kairo_Self, class V> struct Wrapped_witness {
// CXX-NEXT: static::composed_dependent_leaf::Wrap<V> get(const __kairo_Self * self, signed int i) requires requires {
// CXX: template<> struct Deep_witness< ::composed_dependent_leaf::Ext, signed long> {
// CXX-NEXT: static signed long get(const::composed_dependent_leaf::Ext * self, signed int i) {
// CXX: template<> struct Wrapped_witness< ::composed_dependent_leaf::WB, signed int> {
// CXX-NEXT: static::composed_dependent_leaf::Wrap<signed int> get(const::composed_dependent_leaf::WB * self, signed int i) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 28
