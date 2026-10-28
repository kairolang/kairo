// `cxx::std::vector<*Node>`, the `vec::<*Decl>` shape Compiler/ is built
// on: every way in (push_back of a named pointer and of `&x`) and every way
// out (operator[], at, back, a range-for, a by-value parameter), each read
// back as `*Node` -- not `unsafe *Node` -- and called through with `->`.
//
// The element is `Node*` to C++, and a `Node*` read out of a header is
// `unsafe *Node` by default; inside an instance whose ARGUMENT wrote the
// pointer, the argument's flavour wins (TypeImport::note_pointer_arg).
// `ptrs[0]->id` steps through `reference` (`Node*&`), which EmitIR now
// treats as the pointer it refers to.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
    fn get(self) -> i32 { return self.id }
}

fn sum(v: cxx::std::vector<*Node>) -> i32 {
    var s = 0
    for p in v { s += p->id }
    return s
}

fn main() -> i32 {
    var a = Node(3)
    var b = Node(4)
    var c = Node(5)
    var ptrs: cxx::std::vector<*Node>
    var *pa = &a
    var *pb = &b
    ptrs.push_back(pa)
    ptrs.push_back(pb)
    ptrs.push_back(&c)
    var *first = ptrs.at(0)
    var *last = ptrs.back()
    var keep: *Node = ptrs[1]                 // a safe pointer, no cast
    var r = ptrs[0]->id + ptrs[1]->get()     // 3 + 4
    r += first->id + last->id + keep->id      // 3 + 5 + 4
    r += sum(ptrs)                            // 12
    return r                                  // 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
