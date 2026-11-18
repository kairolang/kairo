// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
//
// A derived pointer reaches `*Base` and `*const Base` at the same rank;
// C++ takes the less qualified one ([over.ics.rank]/3.2.1), so the call is
// not ambiguous. `cast(p)` and `is_recovery(p)` in the compiler's own tree
// are not SC064E for a derived `p`.
// CHECK-NOT: SC064E

class A { pub var k: i32 = 0 }
class B derives A { }
class C derives B { }

fn pick(p: unsafe *A) -> i32 { return 1 }
fn pick(p: unsafe *const A) -> i32 { return 2 }

fn from_derived(p: unsafe *C) -> i32 { return pick(p) }
fn from_mid(p: unsafe *B) -> i32 { return pick(p) }
fn from_base(p: unsafe *A) -> i32 { return pick(p) }
