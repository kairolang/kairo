// Kairo pointers as the VALUES of an imported map: `operator[]` (which
// returns `mapped_type&`, a `Node*&`), at, insert_or_assign, in a hash map
// and an ordered one. Each value reads back as `*Node`.

ffi "c++" import "unordered_map"
ffi "c++" import "map"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
    fn get(self) -> i32 { return self.id }
}

fn main() -> i32 {
    var b = Node(4)
    var c = Node(5)
    var m: cxx::std::unordered_map<i32, *Node>
    var *pb = &b
    m[1] = pb
    m.insert_or_assign(2, &c)
    var o: cxx::std::map<i32, *Node>
    o[7] = &c
    var r = m[1]->id + m.at(2)->get()         // 4 + 5
    r += o[7]->id + o.at(7)->get()            // 10
    r += m.size() as i32                      // 2
    return r                                  // 21
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
