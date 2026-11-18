// RUN: { %kairo %s --type-check-only --cmax-type-alias-depth=8  2>&1 || true; } | %FileCheck %s --check-prefix=TIGHT
// RUN: { %kairo %s --type-check-only --cmax-type-alias-depth=64 2>&1 || true; } | %FileCheck %s --check-prefix=LOOSE --allow-empty
//
// R036 / --cmax-type-alias-depth: the alias-chain budget is its own, separate
// from the resolution stack's scope-depth cap.
//
// It has to be separate in both directions. The stack counts EVERY decl T
// descends into, so a two-link chain reached from inside a deep generic body
// would trip a budget the user set for alias depth alone; and a long chain of
// re-exported aliases says nothing about how deeply nested its scopes are.
// Only one of the two limits has a message that can name a flag that helps.
//
// The chain is written outermost-first on purpose. Declared the other way the
// whole-TU walk settles each link before anything references it, every later
// expansion takes the already-Resolved fast path, and the nesting this test
// exists to measure never happens.

type A0 = A1
type A1 = A2
type A2 = A3
type A3 = A4
type A4 = A5
type A5 = A6
type A6 = A7
type A7 = A8
type A8 = A9
type A9 = A10
type A10 = A11
type A11 = A12
type A12 = A13
type A13 = A14
type A14 = A15
type A15 = A16
type A16 = A17
type A17 = A18
type A18 = A19
type A19 = A20
type A20 = i32

// A0 sits 20 links above the builtin, so a budget of 8 stops it and a budget
// of 64 does not. The report names the alias that ran past the limit.

// TIGHT: R036E{{.*}}expands through more than 8 nested aliases
// TIGHT: R036N{{.*}}the chain continues from its target

// LOOSE-NOT: R036E
