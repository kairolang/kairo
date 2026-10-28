// The element keeps the flavour its argument wrote, so the pointer rules
// apply to it as to any `*Node`: a maybe-null `*Node?` cannot go into a
// `vector<*Node>` unchecked, and an `unsafe *Node` does not become a safe
// one implicitly.

ffi "c++" import "vector"

class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

fn find(n: *Node, ok: bool) -> *Node? {
    if ok { return n }
    return null
}

fn main() -> i32 {
    var a = Node(3)
    var ptrs: cxx::std::vector<*Node>
    var *maybe? = find(&a, true)
    ptrs.push_back(maybe)
    unsafe {
        var unsafe *raw = &a as unsafe *Node
        ptrs.push_back(raw)
    }
    return ptrs[0]->id
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:22:20: error [SC001E]: 'maybe' may be null here; check it with 'if maybe?' first
// DIAG-NEXT: {{.*}}:21:5: note [I900N]: 'maybe' is given a value that may be null here
// DIAG: {{.*}}:25:9: error [SC063E]: no matching overload for call to 'push_back'
// DIAG-NEXT: {{.*}}/vector.h:462:3: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe *Node' to parameter '__x' of type 'const *Node&'
// DIAG-NEXT: {{.*}}/vector.h:464:3: note [I900N]: candidate not viable: cannot convert argument of type 'unsafe *Node' to parameter '__x' of type '*Node&&'
// END-GENERATED-CHECKS(DIAG)
