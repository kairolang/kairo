// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: %t.exe; test $? -eq 3
//
// A local deduced from a member read through a `: type` parameter's pointer
// (`var head = prev->first`) has no type until the instance; it is emitted
// `auto`. A member step through it (`tail->next`) used to be the EmitIR ICE
// "unbound member step reached codegen; gate failure", plus an I011W "no
// inferred type" for the local. Found compiling the migrated
// AST/Mixin/Redeclarable.k to an object (self-host phase 5.3).

// DIAG-NOT: I011W
// DIAG-NOT: I003E

class Node {
    pub var next:  unsafe *Node = &null
    pub var first: unsafe *Node = &null
    pub var id:    i32 = 0
}

class <T: type> Ring {
    fn last_of(self, prev: unsafe *T) -> i32 {
        var head = prev->first
        var tail = head
        var n = 0
        while tail->next != head {
            tail = tail->next
            n += 1
        }
        return n + tail->id
    }
}

fn main() -> i32 {
    var a: Node
    var b: Node
    var c: Node
    var pa = unsafe &a
    var pb = unsafe &b
    var pc = unsafe &c
    a.first = pa
    a.next = pb
    b.next = pc
    c.next = pa
    c.id = 1
    var r: Ring<Node>
    // two steps from a to c, plus c.id
    return r.last_of(pa)
}
