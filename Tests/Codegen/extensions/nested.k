// nested.k -- exit 9
class Tree {
    pub struct Node { var value: i32; }
    priv var root_: Node;
    priv var count: i32;
}

extend Tree {
    fn root(const self) -> Node { return self.root_; }
    fn set(self, v: i32) { self.root_ = Node { value: v }; self.count += 1; }
    fn size(const self) -> i32 { return self.count; }
}

fn main() -> i32 {
    var t = Tree();
    t.set(5);
    t.set(7);
    return t.root().value + t.size();
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// The scope is defined after its target (a Complete edge), so a member may
// return a nested type by value.
// CXX: class Tree {
// CXX: struct __kairo_ext_Tree {
// CXX-NEXT: static::nested::Tree::Node root(const::nested::Tree * self);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 9
