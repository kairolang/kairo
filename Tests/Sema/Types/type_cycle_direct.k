// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// IMPORTS.md §8 item 10 / §6.3: a `complete` edge cycle is a Kairo error owned
// by TypeCycleCheck, so that EmitPlan's topological sort may assert instead of
// diagnose and LayoutPass may assume acyclicity.
//
// The whole content of the pass is WHICH edges count. A by-value edge puts a
// type's size inside another type's size: a value field, a base class, a fixed
// array element, a tuple element, a generic argument the template stores by
// value, a nullable's inner type. Everything else is satisfied by a forward
// declaration and can never close a cycle. One edge kind per file:
//   type_cycle_direct.k       a field of the record's own type (this file)
//   type_cycle_mutual.k       two records holding each other
//   type_cycle_array_tuple.k  through a fixed array and a tuple
//   type_cycle_nullable.k     through `T?`
//   type_cycle_base.k         through base classes
//   type_cycle_generic.k      through a generic argument stored by value
//   type_cycle_indirection.k  pointers and containers: never a cycle

class Node {
    var next: Node;
}
// DIAG: SC002E{{.*}}'Node' contains itself by value
// DIAG: 'Node' holds 'Node' by value, closing the cycle

fn main() -> i32 { return 0; }

// DIAG-NOT: SC002E
