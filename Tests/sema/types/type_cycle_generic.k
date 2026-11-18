// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// A by-value containment cycle that closes THROUGH a generic instantiation.
//
// `Box<UsesBox>` stores its argument by value, so `UsesBox` contains itself
// and has no finite layout -- exactly the error TypeCycleCheck exists to
// report (see type_cycle_direct.k for the other edge kinds).
//
// This was deferred to M2 on the reading that deciding whether `Box<X>`
// stores X by value needs the INSTANTIATED layout. It does not: whether a
// template stores parameter i by value is a property of the PATTERN's
// fields (`var v: T` is by value, `var p: *T` is not), and TypeCycleCheck
// asks the pattern, never the instance shell -- which has no fields until
// M2 and would answer "by nothing" for every instance, including a tuple's
// `(i32, Arr)` (TupleRecords). The instance shell's own size stays unknown
// until M2; only the by-value edge question is settled here.
//
// The negative control is here too: `Ptr<T>` holds `*T`, so `UsesPtr` must
// stay clean. A fix that reports UsesBox by also reporting UsesPtr has just
// broken every recursive generic data structure.

class <T> Box { var v: T; }
class <T> Ptr { var p: *T; }

class UsesBox { var b: Box<UsesBox>; }
// DIAG: SC002E{{.*}}'UsesBox' contains itself by value

class UsesPtr { var p: Ptr<UsesPtr>; }
// DIAG-NOT: 'UsesPtr' contains itself
