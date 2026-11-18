// Nullable pointers as elements: `vector<*Node?>`.
//
// To C++ `*Node?` is `::builtin::Nullable<Node*>` (NullableTypeLowering).
// Phase A knows it through the Nullable lang item's stand-in (TypeExport),
// and the fill reads every `Nullable<Node*>` back as `*Node?` -- with the
// `Node*` inside it kept a safe `*Node`, as for `vector<*Node>` -- so a
// `*Node` and `null` both go in, and each element narrows with `?` before
// `->`. `var *head? = ptrs[0]` takes the element out of the C++ reference
// `operator[]` returns. `vector<*Node>` and `vector<unsafe *Node>`:
// vector_ptr.k, unsafe_ptr.k.

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
    var *head? = ptrs[0]
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
