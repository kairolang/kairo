// Associated types (interfaces.mdx, Associated Types): a conformer supplies
// `type Node` with a type alias, a requirement names it as `Self::Node`, and
// a generic body names it through its parameter as `T::Node`.
//
// XFAIL: *
// Ticket "[Sema] Associated types are parsed but not compiled"
// (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today `Self::Node` and
// `T::Node` do not resolve and conformers do not supply them (status.mdx, Not
// Compiled Yet). When it XPASSes, delete the XFAIL -- the run below is
// already the real assertion.

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

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
