// Nullable pointers as elements: `vector<*Node?>`.
//
// XFAIL: *
// Waiting on a phase-A spelling of `*Node?`. To C++ it is
// `::builtin::Nullable<Node*>` (NullableTypeLowering), a Kairo ADT that
// TypeExport has no stand-in for, so the instance cannot be filled from
// clang; member lookup then walks the pattern and the calls below do not
// resolve. (Spelling it `Node*` instead fills the instance but emits
// `std::vector<Node*>` beside `Nullable<Node*>` values, which clang
// rejects.) `vector<*Node>` and `vector<unsafe *Node>` work: vector_ptr.k,
// unsafe_ptr.k.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn main() -> i32 {
    var a = Node(3)
    var ptrs: cxx::std::vector<*Node?>
    var *pa = &a
    ptrs.push_back(pa)
    ptrs.push_back(null)
    var n = 0
    for p in ptrs {
        if p? { n += p->id } else { n += 10 }
    }
    var head = ptrs[0]
    if head? { n += head->id }
    return n                                  // 3 + 10 + 3 = 16
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 16
