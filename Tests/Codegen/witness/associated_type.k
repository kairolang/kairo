// Associated types (interfaces.mdx, Associated Types): a conformer supplies
// `type Node` with a type alias, a requirement names it as `Self::Node`, and
// a generic body names it through its parameter as `T::Node`. One template
// body for every conformer: `T::Node` is the witness's member type,
// `typename Graph_witness<G>::Node`, which each conformance's
// specialization declares (MONO.md G5, D2).

interface Graph {
    type Node
    fn first(const self) -> Self::Node
    fn weight(const self, n: Self::Node) -> i32
}

class Road impl Graph {
    type Node = i64
    fn Road(self) { }
    fn first(const self) -> i64 { return 20 }
    fn weight(const self, n: i64) -> i32 { return (n + 1) as i32 }
}

fn <G impl Graph> heaviest(g: G) -> i32 {
    var n: G::Node = g.first()
    return g.weight(n)
}

fn main() -> i32 {
    return heaviest(Road())                     // 20 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: internal compiler error
// CXX: concept Graph_c = requires {
// CXX-NEXT: typename::associated_type::Graph_witness<__kairo_Self>::Node;
// CXX: template<> struct Graph_witness< ::associated_type::Road> {
// CXX-NEXT: using Node = signed long;
// CXX-NEXT: static Node first(const::associated_type::Road * self) {
// CXX: typename::associated_type::Graph_witness<G>::Node n = ::associated_type::Graph_witness<G>::first((& g));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
