// Adjacent behaviour: `vector<unsafe *Node>` keeps handing out `unsafe
// *Node` (the flavour the argument wrote), used inside `unsafe`, and its
// `->` through `reference` is emitted as `->` too.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn main() -> i32 {
    var a = Node(3)
    var ptrs: cxx::std::vector<unsafe *Node>
    unsafe {
        var unsafe *pa = &a as unsafe *Node
        ptrs.push_back(pa)
        var unsafe *back = ptrs[0]
        return ptrs[0]->id + back->id         // 6
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 6
