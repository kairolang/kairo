// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: SC016W
// CHECK-NOT: SC001W
// CHECK-NOT: error
//
// An associated type's bounds are its requires clause. On a plain alias a
// conformance constraint is meaningless (SC016W); on an associated type it
// is the point: the type a conformer supplies must meet it. A structural
// conformer declares every associated type, a defaulted one included
// (interfaces.md, Defaults); a generic associated type is not checked at
// conformance (its uses are SC116E, assoc_type_errors.k). The clause's
// subject is the declaration's own name, not a use: no readability lint
// (SC001W) for it.

interface Display { fn show(const self) -> i32 }
interface Graph {
    type Edge impl Display
    type Key impl Display = i32
    type <K impl Display> Map
    fn edges(const self) -> i32
}
pub struct Shown { pub var v: i32 }
extend Shown { pub fn show(const self) -> i32 = self.v }
pub struct G {
    type Edge = Shown
    type Key = Shown
    pub var n: i32
}
extend G { pub fn edges(const self) -> i32 = self.n }
fn <T impl Graph> count(g: T) -> i32 = g.edges()
fn main() -> i32 { return count(G { n: 4 }) }
