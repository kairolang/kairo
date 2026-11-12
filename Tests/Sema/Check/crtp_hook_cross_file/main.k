// Across files: the hook is declared and called through dyn() in
// base.k; the deriving class here spells its parameter `*Node?`, a second
// overload, so Visitor::walk still runs Visitor::visit (SC278W). `*Node`
// would have replaced it (one C++ type with `unsafe *Node`).
import self::base::{Node, Visitor}

class Mine derives Visitor<Mine> {
    fn visit(self, n: *Node?) { }
}

class Fine derives Visitor<Fine> {
    fn visit(self, n: *Node) { }
}

fn main() -> i32 { return 0 }

// --- lit wiring ---
// RUN: cd %S && { %kairo main.k --type-check-only -fduck-generics 2>&1 || true; } | %FileCheck %s
// CHECK:      main.k:8:8: warning [SC278W]: 'Mine::visit' does not replace 'Visitor::visit', which 'Visitor' calls through 'dyn()'
// CHECK-NEXT: fix-it:"{{.*}}main.k":{8:23-8:29}:"unsafe *Node"
// CHECK-NEXT: base.k:8:12: note [SC278N]: the hook 'Visitor' calls
// CHECK-NEXT: base.k:7:42: note [SC278N]: called here through 'dyn()'
// CHECK-NOT:  SC278W
