// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: { %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='I011W' --implicit-check-not='I003E' --implicit-check-not='internal'
// RUN: %t.exe; test $? -eq 9
//
// Neighbours of a local deduced through a `: type` parameter: a value local
// (`var id = prev->id`), a local copied from another deduced local, and a
// two-step member chain through deduced locals. None is an internal error.

class Node {
    pub var next:  unsafe *Node = &null
    pub var id:    i32 = 0
}

class <T: type> Ring {
    fn value_of(self, p: unsafe *T) -> i32 {
        var id = p->id
        var copy = id
        return copy
    }
    fn two_ahead(self, p: unsafe *T) -> i32 {
        var a = p->next
        var b = a->next
        var c = b
        return c->id
    }
}

fn main() -> i32 {
    var a: Node
    var b: Node
    var c: Node
    var pa = unsafe &a
    a.id = 2
    a.next = unsafe &b
    b.next = unsafe &c
    c.id = 7
    var r: Ring<Node>
    return r.value_of(pa) + r.two_ahead(pa)
}
