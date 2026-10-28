// One of the constructs Compiler/ is written with, checked on Stage 1 ahead
// of self-hosting (2026-10-24 probe; tickets in private/IMPORTANT/TICKETS.TXT).
//
// An imported container of Kairo object pointers, the `vec::<*Decl>` shape
// Compiler/ uses everywhere: push a `*Node`, read it back, call through it.
//
// XFAIL: *
// Waiting on two things. (1) The element type: `vector<*Node>` imports its
// element as `unsafe *Node`, so push_back(`*Node`) is SC063E ("cannot
// convert argument of type '*Node' to parameter '__x' of type 'const unsafe
// *Node&'"). (2) Even spelled `vector<unsafe *Node>` inside `unsafe`,
// `ptrs[0]->id` is emitted with `.`: CL001E "member reference type
// 'value_type' (aka 'Node *') is a pointer; did you mean to use '->'?".
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn main() -> i32 {
    var a = Node(3)
    var b = Node(4)
    var ptrs: cxx::std::vector<*Node>
    var *pa = &a
    var *pb = &b
    ptrs.push_back(pa)
    ptrs.push_back(pb)
    return ptrs[0]->id + ptrs[1]->id           // 3 + 4
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
