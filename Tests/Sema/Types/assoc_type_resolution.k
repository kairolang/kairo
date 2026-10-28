// Associated types resolve once, at the definition, through the bound
// (interfaces.md, Associated Types; MONO.md D0). `Self::Node` inside the
// interface and `T::Node` in a body bounded `T impl Graph` are one abstract
// type, so a requirement returning `Self::Node` called through the bound
// types as `T::Node` and initializes a `var x: T::Node`. An inherited
// associated type (`Big derives Graph`) is the same entity through either
// interface. At an instance the fact `T::Node := S` is computed by
// substitution: `pick(Road())` is an i64, `pick(Map())` a City.

interface Graph {
    type Node
    fn first(const self) -> Self::Node
    fn weight(const self, n: Self::Node) -> i32
}

interface Big derives Graph {
    fn second(const self) -> Self::Node
}

struct City { pub var id: i32 }

class Road impl Graph {
    type Node = i64
    fn Road(self) { }
    fn first(const self) -> i64 { return 20 }
    fn weight(const self, n: i64) -> i32 { return n as i32 }
}

class Map {
    type Node = City
    fn Map(self) { }
    fn first(const self) -> City { return City { id: 7 } }
    fn weight(const self, n: City) -> i32 { return n.id }
}

class Both impl Big {
    type Node = i32
    fn Both(self) { }
    fn first(const self) -> i32 { return 1 }
    fn weight(const self, n: i32) -> i32 { return n }
    fn second(const self) -> i32 { return 2 }
}

fn <G impl Graph> heaviest(g: G) -> i32 {
    var n: G::Node = g.first()
    return g.weight(n)
}

fn <G impl Graph> pick(g: G) -> G::Node { return g.first() }

fn <B impl Big> both(b: B) -> B::Node {
    var a: B::Node = b.first()
    var c: B::Node = b.second()
    return c
}

fn main() -> i32 {
    var l: i64 = pick(Road())
    var c: City = pick(Map())
    var k: i32 = both(Both())
    return heaviest(Road()) + heaviest(Map()) + c.id + k
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: CallExpr {{.*}}@ 45:22 {{.*}}: G::Node
// SEMA: CallExpr {{.*}}@ 49:50 {{.*}}: G::Node
// SEMA: CallExpr {{.*}}@ 52:22 {{.*}}: B::Node
// SEMA: CallExpr {{.*}}@ 53:22 {{.*}}: B::Node
// SEMA: CallExpr {{.*}}@ 58:18 {{.*}}: i64
// SEMA: CallExpr {{.*}}@ 59:19 {{.*}}: City
// SEMA: CallExpr {{.*}}@ 60:18 {{.*}}: i32
