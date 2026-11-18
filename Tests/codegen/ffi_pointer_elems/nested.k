// The Compiler/ shapes one level up: a record holding a vector of pointers
// to its own type (a tree of decls), walked recursively, and a vector of
// vectors of pointers. The outer vector's members name the inner
// `vector<Node*>`; the inner instance keeps `*Node` because the pointer
// arguments of an argument are recorded too (TypeImport::note_pointer_arg).

ffi "c++" import "vector"

class Node {
    pub var id: i32
    pub var kids: cxx::std::vector<*Node>
    fn Node(self, id: i32) { self.id = id }
}

fn total(n: *Node) -> i32 {
    var s = n->id
    for k in n->kids { s += total(k) }
    return s
}

fn main() -> i32 {
    var root = Node(1)
    var l = Node(2)
    var r = Node(3)
    var rr = Node(4)
    root.kids.push_back(&l)
    root.kids.push_back(&r)
    r.kids.push_back(&rr)
    var rows: cxx::std::vector<cxx::std::vector<*Node>>
    rows.push_back(root.kids)
    rows[0].push_back(&rr)
    return total(&root) + rows[0][2]->id + (rows[0].size() as i32)   // 10 + 4 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 17
