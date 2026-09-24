// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// XFAIL: *
//
// DEFERRED TO M2: a by-value containment cycle that closes THROUGH a generic
// instantiation.
//
// `Box<UsesBox>` stores its argument by value, so `UsesBox` contains itself
// and has no finite layout -- exactly the error TypeCycleCheck exists to
// report (see type_cycle.k for the non-generic half, which does work).
//
// It is not reported today, and that is a decision rather than an oversight.
// RESOLUTION.md 2.8: "TypeCycleCheck / LayoutPass treat a `RecordType::decl`
// that is `is_instance() && !instantiated` as 'size unknown until M2', never
// as empty." Deciding whether `Box<UsesBox>` stores its argument by value
// means looking at the INSTANTIATED template's layout, and instantiation is
// M2, which is [MISSING] (RESOLUTION.md 2.9).
//
// The negative control is here too: `Ptr<T>` holds `*T`, so `UsesPtr` must
// stay clean once this lands. A fix that reports UsesBox by also reporting
// UsesPtr has just broken every recursive generic data structure.

class <T> Box { var v: T; }
class <T> Ptr { var p: *T; }

class UsesBox { var b: Box<UsesBox>; }
// DIAG: SC002E{{.*}}'UsesBox' contains itself by value

class UsesPtr { var p: Ptr<UsesPtr>; }
// DIAG-NOT: 'UsesPtr' contains itself
