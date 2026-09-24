// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// IMPORTS.md §8 item 10 / §6.3: a `complete` edge cycle is a Kairo error owned
// by TypeCycleCheck, so that EmitPlan's topological sort may assert instead of
// diagnose and LayoutPass may assume acyclicity.
//
// The whole content of the pass is WHICH edges count. A by-value edge puts a
// type's size inside another type's size: a value field, a base class, a fixed
// array element, a tuple element, a generic argument the template stores by
// value. Everything else is satisfied by a forward declaration and can never
// close a cycle -- pointer, nullable, vector, map, set. Both halves are
// asserted below; the second half is the one a naive "does the type mention
// itself" check gets wrong.

// --- direct self-reference -------------------------------------------------

class Node {
    var next: Node;
}
// DIAG: SC002E{{.*}}'Node' contains itself by value
// DIAG: 'Node' holds 'Node' by value, closing the cycle

// --- mutual recursion, two hops --------------------------------------------

class A { var b: B; }
class B { var a: A; }
// DIAG: SC002E{{.*}}'A' contains itself by value
// DIAG: 'A' holds 'B' by value
// DIAG: 'B' holds 'A' by value, closing the cycle

// --- through a fixed array and a tuple -------------------------------------

struct Arr  { var a: [Arr2; 4]; }
struct Arr2 { var t: (i32, Arr); }
// DIAG: SC002E{{.*}}'Arr' contains itself by value
// DIAG: 'Arr' holds 'Arr2' by value
// DIAG: 'Arr2' holds 'Arr' by value, closing the cycle

// --- through base classes ---------------------------------------------------
//
// A base contributes its whole layout, so `derives` is a by-value edge.
// `implements` is not: an interface is structural and carries no storage.

class Base derives Leaf { }
class Leaf derives Base { }
// DIAG: SC002E{{.*}}'Base' contains itself by value
// DIAG: 'Base' holds 'Leaf' by value
// DIAG: 'Leaf' holds 'Base' by value, closing the cycle

// --- generic arguments: by value only when the template stores by value -----
//
// `Box<T>` holds its T, so Box<UsesBox> puts a UsesBox inside a UsesBox.
// `Ptr<T>` only points at its T, so Ptr<UsesPtr> is a forward declaration's
// worth of dependency and NOT a cycle. Discriminating these two is why the
// generic-argument edge is computed from the template's own layout rather
// than assumed.

class <T> Box { var v: T; }
class <T> Ptr { var p: *T; }

class UsesPtr { var p: Ptr<UsesPtr>; }

// The by-VALUE half of this pair (`class UsesBox { var b: Box<UsesBox>; }`)
// needs M2 and lives in type_cycle_generic.k, marked XFAIL. See there.

// --- indirection breaks every cycle -----------------------------------------
//
// Nothing below is diagnosed. If any of these ever starts erroring, the edge
// classification has drifted and every recursive data structure in the
// language stopped compiling.

class ByPointer  { var next: *ByPointer;      }
class ByNullable { var next: ByNullable?;     }
class ByVector   { var kids: [ByVector];      }
class ByMap      { var kids: {i32: ByMap};    }
class BySet      { var kids: {BySet};         }

fn main() -> i32 { return 0; }

// Exactly five errors, all SC002E, all above. No trailing diagnostics.
// DIAG-NOT: SC002E
