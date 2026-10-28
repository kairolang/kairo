// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: conformance_qualified_generic.k:19:52: error [SC001E]: no bound on 'C' provides 'Container<bool>::get'; bound it 'impl Container<bool>'
// CHECK: conformance_qualified_generic.k:13:31: note [I900N]: 'get' is required here
// CHECK: conformance_qualified_generic.k:23:19: error [SC028E]: cannot convert 'i32' to 'bool'
// CHECK: conformance_qualified_generic.k:24:13: error [SC001E]: 'Box' does not conform to 'Container<bool>': no member 'get' with the requirement's signature
// CHECK: conformance_qualified_generic.k:13:31: note [I900N]: 'get' is required here
// CHECK: conformance_qualified_generic.k:25:13: error [SC001E]: 'Container' is generic, and a qualified call names its instance: write 'Container<...>::get'
// CHECK: conformance_qualified_generic.k:13:5: note [I900N]: 'Container' is declared here
// CHECK-NOT: error
// `I<A>::m(x)`: the qualifier's arguments are the requirement's interface
// parameters, so the call types as `-> T` at A (i32 here, not bool), and x
// must conform to I<A>. A bare generic `I::m` names no instance.
pub interface <T> Container { fn get(const self, i: i32) -> T }
pub class Box impl Container<i32> {
    fn Box(self) { }
    fn get(const self, i: i32) -> i32 = i + 2
}
pub fn <C impl Container<i32>> good(c: C) -> i32 = Container<i32>::get(c, 0)
pub fn <C impl Container<i32>> bad(c: C) -> bool = Container<bool>::get(c, 0)
fn main() -> i32 {
    var b = Box()
    var a: i32 = Container<i32>::get(b, 3)
    var y: bool = Container<i32>::get(b, 3)
    var z = Container<bool>::get(b, 3)
    var w = Container::get(b, 3)
    return a
}
// A generic interface's `-> Self` reads as the receiver, not as the
// qualifier's instance: C here, and Pair on a concrete Pair.
// CHECK: conformance_qualified_generic.k:[[@LINE+8]]:63: error [SC028E]: cannot convert 'C' to 'i32'
pub interface <T> Cloner { fn clone(const self) -> Self }
pub class Pair impl Cloner<bool> {
    pub var n: i32 = 1
    fn Pair(self) { }
    fn clone(const self) -> Pair = Pair()
}
pub fn <C impl Cloner<bool>> keep(c: C) -> C = Cloner<bool>::clone(c)
pub fn <C impl Cloner<bool>> lose(c: C) -> i32 { var k: i32 = Cloner<bool>::clone(c); return k }
fn other() -> i32 { var p = Pair(); var q: Pair = Cloner<bool>::clone(p); return q.n }
// CHECK-NOT: error
