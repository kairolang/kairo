// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: SC016W
// CHECK-NOT: error
//
// An associated type's bounds are its requires clause. On a plain alias a
// conformance constraint is meaningless (SC016W); on an associated type it
// is the point: the type a conformer supplies must meet it. An interface
// with associated types still types and conforms (they are not compiled
// further yet).

interface Display { fn show(const self) -> i32 }
interface Graph {
    type Edge impl Display
    type Key impl Display = i32
    type <K impl Display> Map
    fn edges(const self) -> i32
}
pub struct G { pub var n: i32 }
extend G { pub fn edges(const self) -> i32 = self.n }
fn <T impl Graph> count(g: T) -> i32 = g.edges()
fn main() -> i32 { return count(G { n: 4 }) }
