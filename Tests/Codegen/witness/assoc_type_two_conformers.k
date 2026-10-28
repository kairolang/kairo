// One generic body, two conformers with different associated types: Road
// (explicit, `type Node = i64`) and Map (structural, `type Node = City`).
// `G::Node` in the body is `typename Graph_witness<G>::Node`, and each row's
// specialization declares it, so the one template is right for both
// instances (MONO.md G5, D2). At the call, `pick(Map())` IS a City: the
// instance fact `G::Node := City`, computed by substitution.

interface Graph {
    type Node
    fn first(const self) -> Self::Node
    fn weight(const self, n: Self::Node) -> i32
}

struct City { pub var id: i32 }

class Road impl Graph {
    type Node = i64
    fn Road(self) { }
    fn first(const self) -> i64 { return 20 }
    fn weight(const self, n: i64) -> i32 { return (n + 1) as i32 }
}

class Map {
    type Node = City
    fn Map(self) { }
    fn first(const self) -> City { return City { id: 7 } }
    fn weight(const self, n: City) -> i32 { return n.id * 2 }
}

fn <G impl Graph> heaviest(g: G) -> i32 {
    var n: G::Node = g.first()
    return g.weight(n)
}

fn <G impl Graph> pick(g: G) -> G::Node { return g.first() }

fn main() -> i32 {
    var c: City = pick(Map())
    var l: i64 = pick(Road())
    return heaviest(Road()) + heaviest(Map()) + c.id + (l as i32)   // 21 + 14 + 7 + 20
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX-DAG: template<> struct Graph_witness< ::assoc_type_two_conformers::Road> {
// CXX-DAG: using Node = signed long;
// CXX-DAG: template<> struct Graph_witness< ::assoc_type_two_conformers::Map> {
// CXX-DAG: using Node = ::assoc_type_two_conformers::City;
// CXX-DAG: typename::assoc_type_two_conformers::Graph_witness<G>::Node n = ::assoc_type_two_conformers::Graph_witness<G>::first((& g));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 62
