// A derived method with the name and arity of a hook its CRTP base
// calls through `self.dyn()`, but other parameter types, is a second
// overload (classes-inheritance.mdx: overload sets merge), so the base's
// `self.dyn()->hook(n)` still runs the base's hook: SC278W, a note at the
// base hook and at the call, and a fix-it to the base's parameter type when
// only pointer safety, nullability or const differ. `*T` and `unsafe *T`
// are one C++ type, so that pair does replace the hook and is not warned.
import std::io

class Node { var v: i32 }
class Other { var w: i32 }

class <D: type> Visitor {
    fn dyn(self) -> unsafe *D { return unsafe ((&self) as *D) }
    fn walk(self, n: unsafe *Node) {
        self.dyn()->nullable(n)
        self.dyn()->safe(n)
        self.dyn()->exact(n)
        self.dyn()->record(n)
        self.dyn()->konst(n)
        self.dyn()->quiet(n)
        self.dyn()->two(n, 1)
    }
    fn nullable(self, n: unsafe *Node) { io::println("base nullable") }
    fn safe(self, n: unsafe *Node) { io::println("base safe") }
    fn exact(self, n: unsafe *Node) { io::println("base exact") }
    fn record(self, n: unsafe *Node) { io::println("base record") }
    fn konst(self, n: unsafe *Node) { io::println("base konst") }
    fn quiet(self, n: unsafe *Node) { io::println("base quiet") }
    fn two(self, n: unsafe *Node, k: i32) { io::println("base two") }
    fn helper(self, n: unsafe *Node) { }
}

class Mine derives Visitor<Mine> {
    fn nullable(self, n: *Node?) { io::println("mine nullable") }
    fn safe(self, n: *Node) { io::println("mine safe") }
    fn exact(self, n: unsafe *Node) { io::println("mine exact") }
    fn record(self, n: unsafe *Other) { io::println("mine record") }
    fn konst(const self, n: unsafe *Node) { io::println("mine konst") }
    @no_warn(SC278W)
    fn quiet(self, n: *Node?) { io::println("mine quiet") }
    fn two(self, n: unsafe *Node) { io::println("mine two, other arity") }
    fn helper(self, n: *Node?) { }
}

// A mixin between: Final reaches Visitor through Mid<Final>.
class <T: type> Mid derives Visitor<T> { }
class Final derives Mid<Final> {
    fn nullable(self, n: *const Node) { }
}

fn main() -> i32 {
    var m = Mine()
    var n = Node()
    unsafe { m.walk(&n as unsafe *Node) }
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      .k:35:8: warning [SC278W]: 'Mine::nullable' does not replace 'Visitor::nullable', which 'Visitor' calls through 'dyn()': the parameter types differ, so that call still runs 'Visitor::nullable'
// DIAG-NEXT: fix-it:"{{.*}}":{35:26-35:32}:"unsafe *Node"
// DIAG-NEXT: .k:24:8: note [SC278N]: the hook 'Visitor' calls; to replace it, take exactly its parameters
// DIAG-NEXT: .k:16:9: note [SC278N]: called here through 'dyn()'; with both overloads visible it picks 'Visitor::nullable'
// DIAG-NOT:  'Mine::safe'
// DIAG-NOT:  'Mine::exact'
// DIAG:      .k:38:8: warning [SC278W]: 'Mine::record' does not replace 'Visitor::record'
// DIAG-NOT:  fix-it
// DIAG:      .k:39:8: warning [SC278W]: 'Mine::konst' does not replace 'Visitor::konst', which 'Visitor' calls through 'dyn()': the base's takes 'self' and this one 'const self'
// DIAG-NOT:  fix-it
// DIAG-NOT:  'Mine::quiet'
// DIAG-NOT:  'Mine::two'
// DIAG-NOT:  'Mine::helper'
// DIAG:      .k:49:8: warning [SC278W]: 'Final::nullable' does not replace 'Visitor::nullable'
// DIAG-NEXT: fix-it:"{{.*}}":{49:26-49:37}:"unsafe *Node"
// DIAG-NOT:  SC278W
//
// The hazard itself: the base's hook runs for every mismatched one.
// RUN: rm -rf %t.d && %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      base nullable
// OUT-NEXT: mine safe
// OUT-NEXT: mine exact
// OUT-NEXT: base record
// OUT-NEXT: base konst
// OUT-NEXT: base quiet
// OUT-NEXT: base two
