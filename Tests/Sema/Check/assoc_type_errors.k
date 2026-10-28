// Naming an associated type wrongly is diagnosed where it is named, at
// type resolution, never deferred to an ICE (interfaces.md, Associated
// Types; MONO.md G5):
//  - one no bound declares, or one two bounds both declare;
//  - one outside its interface, with no type parameter to reach it;
//  - a default that breaks the order rule (it sees only earlier ones);
//  - the parts not built yet: a generic associated type, a member of an
//    associated type, and a derived interface giving an inherited
//    associated type a default (SC116E).
// The body-level cases are assoc_type_body_errors.k: these stop the TU
// before bodies are typed.

interface Display { fn show(const self) -> i32 }
interface Graph { type Node  fn first(const self) -> Self::Node }
interface Tree  { type Node  fn root(const self) -> i32 }

interface Weighted {
    type Node
    type Edge = (Self::Node, Self::Node)
    type Cost = Self::Weight
    type Weight
    type Loop = Self::Loop
}

interface Sub derives Graph { type Node = i64 }

interface Store {
    type <K impl Display> Map
    type Item
}

fn <T> nobound(x: T) -> T::Node { }
fn <T impl Graph> nosuch(x: T) -> T::Edge { }
fn <T> twice(x: T) -> T::Node requires T impl Graph && T impl Tree { }
fn outside() -> Graph::Node { }
fn <T impl Store> generic(s: T) -> T::Map<i32> { }
fn <T impl Store> member(s: T) -> T::Item::Inner { }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:20:23: error [R001E]: the default of associated type 'Cost' names 'Weight', which is not declared before it; defaults resolve in declaration order
// CHECK-NEXT: assoc_type_errors.k:21:5: note [I900N]: 'Weight' is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:22:23: error [R001E]: the default of associated type 'Loop' names 'Loop', which is not declared before it; defaults resolve in declaration order
// CHECK-NEXT: assoc_type_errors.k:22:5: note [I900N]: 'Loop' is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:25:36: error [SC116E]: redeclaring inherited associated type 'Node' (to give it a default) is not supported yet
// CHECK-NEXT: assoc_type_errors.k:14:19: note [SC116N]: the inherited associated type is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:32:28: error [R025E]: no associated type named 'Node' in the bounds of 'T'
// CHECK-NEXT: assoc_type_errors.k:32:5: note [I900N]: 'T' has no interface bound; a generic body may use only what its bounds declare
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:33:38: error [R025E]: no associated type named 'Edge' in the bounds of 'T'
// CHECK-NEXT: assoc_type_errors.k:33:5: note [I900N]: bound here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:34:26: error [R028E]: 'T::Node' is ambiguous: more than one bound of 'T' declares an associated type 'Node'
// CHECK-NEXT: assoc_type_errors.k:14:19: note [R028N]: one is declared here
// CHECK-NEXT: assoc_type_errors.k:15:19: note [R028N]: another is declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:35:24: error [R001E]: associated type 'Node' of 'Graph' is named outside the interface; name it through a type parameter bounded by 'Graph' ('T::Node')
// CHECK-NEXT: assoc_type_errors.k:14:19: note [I900N]: declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:36:39: error [SC116E]: generic associated type 'Map' is not supported yet
// CHECK-NEXT: assoc_type_errors.k:28:5: note [SC116N]: declared here
// CHECK-NOT: {{error|warning}}
// CHECK: assoc_type_errors.k:37:44: error [SC116E]: a member of associated type 'T::Item' cannot be named yet
// CHECK-NEXT: assoc_type_errors.k:29:5: note [SC116N]: the associated type is declared here
// CHECK-NOT: {{error|warning}}
