// witness/qualified_generic.k -- exit 106
// The qualified form of a GENERIC interface's requirement call,
// `Container<i32>::get(x, ...)`: the qualifier's arguments are the witness's
// trailing arguments. A concrete conformer's call is its own instantiation
// site (Flag's extension member gets its specialization); through a derived
// interface (`Sub<i32>::get`) it is the declaring Container<i32>'s witness;
// on a bounded parameter it goes through the bound the qualifier names --
// with two Sink bounds, each call takes its own. A generic interface's
// `-> Self` is the receiver's type in the witness and at the call.
pub interface <T> Container {
    fn get(const self, i: i32) -> T
    fn put(self, v: T) -> T
}
pub interface <T> Sub derives Container<T> { fn size(const self) -> i32 }
pub interface <T> Sink { fn take(const self, v: T) -> i32 }
pub class Box impl Sub<i32> {
    pub var n: i32 = 0
    fn Box(self) { }
    fn get(const self, i: i32) -> i32 = i + 2
    fn put(self, v: i32) -> i32 { self.n = v; return v * 2 }
    fn size(const self) -> i32 = 7
}
pub struct Flag { pub var on: bool }
extend Flag impl Container<bool> {
    pub fn get(const self, i: i32) -> bool = self.on
    pub fn put(self, v: bool) -> bool = v
}
extend Box {
    pub fn twice(const self) -> i32 = Container<i32>::get(self, 1) * 2
}
pub struct Two { pub var k: i32 }
extend Two impl Sink<i32> { pub fn take(const self, v: i32) -> i32 = self.k + v }
extend Two impl Sink<bool> { pub fn take(const self, v: bool) -> i32 = 10 }
pub interface <T> Cloner { fn clone(const self) -> Self }
extend Flag impl Cloner<i32> { pub fn clone(const self) -> Flag = Flag { on: !self.on } }
pub fn <C impl Cloner<i32>> dup(c: C) -> C = Cloner<i32>::clone(c)
pub fn <C impl Sub<i32>> viasub(c: C) -> i32 = Container<i32>::get(c, 0) + Sub<i32>::size(c)
pub fn <C> both(c: C) -> i32 requires C impl Sink<i32> && C impl Sink<bool> {
    return Sink<i32>::take(c, 1) + Sink<bool>::take(c, true)
}
fn main() -> i32 {
    var b = Box()
    var f = Flag { on: true }
    var t = Two { k: 3 }
    var a: i32 = Container<i32>::get(b, 3)          // 5
    var p = Container<i32>::put(b, 4)                // 8, and b.n = 4
    var s = Sub<i32>::get(b, 0) + Sub<i32>::size(b)  // 9
    var g = 0
    if Container<bool>::get(f, 0) { g = 1 }
    if Container<bool>::put(f, false) { g = 100 }
    var f2 = dup(f)                                   // on: false
    var f3: Flag = Cloner<i32>::clone(f2)             // on: true
    if f3.on && (!f2.on) { g = g + 50 }
    // 5 + 8 + 9 + 6 + 51 + 4 + 9 + 14
    return a + p + s + b.twice() + g + b.n + viasub(b) + both(t)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}witness/qualified_generic.k
// CXX: template<> struct Container_witness<{{ ?}}::{{.*}}::Flag, bool> {
// CXX-NOT: template<> struct Container_witness<{{ ?}}::{{.*}}::Box
// CXX: static __kairo_Self clone(const __kairo_Self * self)
// CXX: template<> struct Cloner_witness<{{ ?}}::{{.*}}::Flag, signed int> {
// CXX-NEXT: static{{ ?}}::{{.*}}::Flag clone(const{{ ?}}::{{.*}}::Flag * self)
// CXX: Container_witness<{{ ?}}::{{.*}}::Box, signed int>::get(self, 1) * 2
// CXX: Cloner_witness<C, signed int>::clone((& c))
// CXX: Sub_witness<C, signed int>::get((& c), 0) +{{ ?}}::{{.*}}::Sub_witness<C, signed int>::size((& c))
// CXX: Sink_witness<C, signed int>::take((& c), 1) +{{ ?}}::{{.*}}::Sink_witness<C, bool>::take((& c), true)
// CXX: signed int a = {{ ?}}::{{.*}}::Container_witness<{{ ?}}::{{.*}}::Box, signed int>::get((& b), 3);
// CXX: Container_witness<{{ ?}}::{{.*}}::Box, signed int>::put((& b), 4);
// CXX: Container_witness<{{ ?}}::{{.*}}::Box, signed int>::get((& b), 0) +{{ ?}}::{{.*}}::Sub_witness<{{ ?}}::{{.*}}::Box, signed int>::size((& b))
// CXX: Container_witness<{{ ?}}::{{.*}}::Flag, bool>::get((& f), 0)
// CXX: Flag f3 = {{ ?}}::{{.*}}::Cloner_witness<{{ ?}}::{{.*}}::Flag, signed int>::clone((& f2));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 106
