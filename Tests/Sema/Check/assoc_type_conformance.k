// A conformer supplies an associated type with a type alias, and the
// requirement is matched with it in place (interfaces.md, Associated
// Types): `fn first(const self) -> Self::Node` is met by `-> i64` when
// `type Node = i64`, and by nothing else. Structural conformance must
// declare EVERY associated type -- a default applies only to a type that
// conforms explicitly (`impl` on its declaration, or `extend ... impl`) --
// and the supplied type must meet the associated type's own bounds.

interface Display { fn show(const self) -> i32 }

interface Graph {
    type Node
    type Edge = i32
    fn first(const self) -> Self::Node
    fn edge(const self) -> Self::Edge
}

interface Catalog {
    type Item impl Display
    fn get(const self) -> Self::Item
}

struct Shown { pub var v: i32 }
extend Shown { pub fn show(const self) -> i32 = self.v }
struct Plain { pub var v: i32 }

// Explicit: Edge takes its default, i32.
class Road impl Graph {
    type Node = i64
    fn Road(self) { }
    fn first(const self) -> i64 { return 1 }
    fn edge(const self) -> i32 { return 2 }
}

// Explicit through an extension: the default applies there too.
class Lane {
    type Node = i64
    fn Lane(self) { }
    fn first(const self) -> i64 { return 1 }
    fn edge(const self) -> i32 { return 2 }
}
extend Lane impl Graph { }

// Structural, declaring both: conforms.
class Path {
    type Node = i64
    type Edge = i64
    fn Path(self) { }
    fn first(const self) -> i64 { return 1 }
    fn edge(const self) -> i64 { return 2 }
}

// Structural, relying on the default: does not conform.
class Trail {
    type Node = i64
    fn Trail(self) { }
    fn first(const self) -> i64 { return 1 }
    fn edge(const self) -> i32 { return 2 }
}

// No Node at all: the missing associated type is the error, not the
// requirements that name it.
class Bare {
    fn Bare(self) { }
    fn first(const self) -> i64 { return 1 }
    fn edge(const self) -> i32 { return 2 }
}

// Node declared, but `first` returns something else.
class Wrong {
    type Node = i64
    type Edge = i32
    fn Wrong(self) { }
    fn first(const self) -> i32 { return 1 }
    fn edge(const self) -> i32 { return 2 }
}

class GoodShelf { type Item = Shown  fn GoodShelf(self) { }  fn get(const self) -> Shown { return Shown { v: 1 } } }
class BadShelf  { type Item = Plain  fn BadShelf(self) { }   fn get(const self) -> Plain { return Plain { v: 1 } } }

fn <G impl Graph> use(g: G) -> i32 { return 0 }
fn <C impl Catalog> shelve(c: C) -> i32 { return 0 }

fn main() -> i32 {
    var a = use(Road()) + use(Lane()) + use(Path())
    var b = use(Trail()) + use(Bare()) + use(Wrong())
    var c = shelve(GoodShelf()) + shelve(BadShelf())
    return a + b + c
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_conformance.k:86:13: error [SC001E]: 'Trail' does not conform to 'Graph': it declares no associated type 'Edge'
// CHECK-NEXT: assoc_type_conformance.k:81:5: note [{{.*}}]: required by this bound
// CHECK-NEXT: assoc_type_conformance.k:13:5: note [{{.*}}]: 'Edge' has a default, but a default applies only to a type that declares 'impl Graph'
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_conformance.k:86:28: error [SC001E]: 'Bare' does not conform to 'Graph': it declares no associated type 'Node'
// CHECK-NEXT: assoc_type_conformance.k:81:5: note [{{.*}}]: required by this bound
// CHECK-NEXT: assoc_type_conformance.k:12:5: note [{{.*}}]: 'Node' is required here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_conformance.k:86:42: error [SC001E]: 'Wrong' does not conform to 'Graph': no member 'first' with the requirement's signature
// CHECK-NEXT: assoc_type_conformance.k:81:5: note [{{.*}}]: required by this bound
// CHECK-NEXT: assoc_type_conformance.k:14:5: note [{{.*}}]: 'first' is required here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_conformance.k:87:35: error [SC001E]: 'BadShelf' does not conform to 'Catalog': its associated type 'Item' is 'Plain', which does not meet the bounds 'Item' declares
// CHECK-NEXT: assoc_type_conformance.k:82:5: note [{{.*}}]: required by this bound
// CHECK-NEXT: assoc_type_conformance.k:19:5: note [{{.*}}]: 'Item' and its bounds are declared here
// CHECK-NOT: {{error|warning}}
