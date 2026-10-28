// oop/crtp_modules/app.k -- exit 22
// CRTP across modules: the mixins (bounded and duck) live in mixins.k, the
// class deriving them here. The bounded mixin's `impl Weighted` is checked
// in this TU, where Node is complete, and pinned beside the instance's
// explicit instantiation in its home (this TU); the class template's head
// in mixins.k carries no requires-clause for clang to evaluate at
// `class Node : ... Counter<Node>`. Both mixins sit at nonzero offsets, so
// both casts must adjust the pointer.
import mixins::*

class Base {
    pub var b: i32 = 100
}

class Node derives Base, Counter<Node>, Tagged<Node> impl Weighted {
    pub var w: i32 = 5
    pub fn Node(self) { }
    pub fn weight(const self) -> i32 { return self.w }
}

fn main() -> i32 {
    var n = Node()
    return n.bump() + n.tagged() + n.hits + n.b - 100   // 6 + 15 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
