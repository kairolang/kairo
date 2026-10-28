// interfaces.md, "Associated types and inheritance": a derived interface
// may give an inherited associated type a default if it has none. It was
// SC116E. The derived interface's `type Node = i64` is not a second Node:
// it is the default of Graph's Node for whoever conforms through IntGraph
// explicitly, so `pick` (bounded by Graph) and `pick2` (bounded by
// IntGraph) see one type. A default may name another associated type of
// the derived interface (`Boxed`'s `Node = Self::Inner`), read at the
// conformer. A structural conformer still takes no default (Plain declares
// its Node).

interface Graph {
    type Node
    fn first(const self) -> Self::Node
}

interface IntGraph derives Graph {
    type Node = i64
}

interface Boxed derives Graph {
    type Inner
    type Node = Self::Inner
}

class Road impl IntGraph {
    fn Road(self) { }
    fn first(const self) -> i64 { return 20 }
}

class Crate impl Boxed {
    type Inner = i32
    fn Crate(self) { }
    fn first(const self) -> i32 { return 3 }
}

class Plain {
    type Node = i16
    fn Plain(self) { }
    fn first(const self) -> i16 { return 1 }
}

fn <G impl Graph> pick(g: G) -> G::Node { return g.first() }
fn <G impl IntGraph> pick2(g: G) -> G::Node { return g.first() }

fn main() -> i32 {
    var a: i64 = pick(Road())
    var b: i64 = pick2(Road())
    var c: i32 = pick(Crate())
    var d: i16 = pick(Plain())
    return (a + b) as i32 + c + (d as i32)        // 40 + 3 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 44
