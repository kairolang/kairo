// Imported by cross_module.k; not a test of its own (lit.local.cfg).
ffi "c++" import "vector"

pub class Node {
    pub var id: i32
    fn Node(self, id: i32) { self.id = id }
}

pub fn total(v: cxx::std::vector<*Node>) -> i32 {
    var s = 0
    for p in v { s += p->id }
    return s
}

pub fn largest(v: cxx::std::vector<*Node>) -> *Node {
    var *best = v[0]
    for p in v { if p->id > best->id { best = p } }
    return best
}
