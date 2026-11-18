// Associated types through the forms a bound can take: a GENERIC interface
// (`Container<i32>`: the witness carries the interface's arguments), a
// GENERIC conformer (`class <T> Holder impl Graph { type Node = T }`: the
// alias read through the instance's arguments, one partial-specialization
// witness), and an interface that DERIVES the one declaring the associated
// type (`Big derives Graph`: `B::Node` and Graph's `first() -> Self::Node`
// through B are one type, spelled through the bound's witness,
// `Big_witness<B>::Node`).

interface Graph {
    type Node
    fn first(const self) -> Self::Node
}

interface Big derives Graph {
    fn second(const self) -> Self::Node
}

interface <V> Container {
    type Item
    fn get(const self) -> Self::Item
    fn wrap(const self, v: V) -> i32
}

struct Cell { pub var n: i32 }

class Box impl Container<i32> {
    type Item = Cell
    fn Box(self) { }
    fn get(const self) -> Cell { return Cell { n: 9 } }
    fn wrap(const self, v: i32) -> i32 { return v + 1 }
}

class <T> Holder impl Graph {
    type Node = T
    var v: T
    fn Holder(self, v: T) { self.v = v }
    fn first(const self) -> T { return self.v }
}

class R impl Big {
    type Node = i32
    fn R(self) { }
    fn first(const self) -> i32 { return 1 }
    fn second(const self) -> i32 { return 2 }
}

fn <C impl Container<i32>> item(c: C) -> C::Item { return c.get() }
fn <G impl Graph> pick(g: G) -> G::Node { return g.first() }
fn <B impl Big> both(b: B) -> B::Node {
    var a: B::Node = b.first()
    return b.second()
}

fn main() -> i32 {
    var c: Cell = item(Box())
    var a: i32 = pick(Holder<i32>(5))
    var b: i64 = pick(Holder<i64>(6))
    var r: i32 = both(R())
    return c.n + a + (b as i32) + r   // 9 + 5 + 6 + 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX-DAG: typename::assoc_type_inherited::Container_witness<C, signed int>::Item
// CXX-DAG: typename::assoc_type_inherited::Big_witness<B>::Node a = ::assoc_type_inherited::Big_witness<B>::first((& b));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
