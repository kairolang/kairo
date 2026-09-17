// RUN: { %kairo %s --type-check-only --print-emit-plan 2>/dev/null || true; } | %FileCheck %s --check-prefix=PLAN
//
// IMPORTS.md §6.1-§6.3. The plan is what a C++ header would have provided for
// THIS TU, derived from resolved decl links alone -- no ImportDecl is read
// (invariant 8) and no import order is consulted.
//
// Three things are asserted, and each is a different way for the plan to be
// wrong:
//
//   1. TRANSITIVITY. main imports foo, never bar. `foo::F` holds a `bar::B`
//      by value, so B's definition has to precede F's, in main.cpp. The
//      closure finds it; nothing else can.
//   2. EDGE STRENGTH. `bar::Deep` is reached only through a pointer, so it
//      gets a tier-0 forward declaration and NO definition. A plan that
//      cannot tell those apart emits every reachable type in full and the
//      preamble grows without bound.
//   3. REACHABILITY. `foo::Unused` is never named, directly or transitively,
//      and must not appear at all.
//
// Ordering: tier 1 is topologically sorted on `complete` edges, so B precedes
// F regardless of which file each was written in.

import foo;

fn main() -> i32 {
    var f: foo::F;
    return foo::use_f(f);
}

// The dump covers EVERY TU in the graph now, own decls included, and each
// non-entry TU gets a second (header) plan besides its preamble. So every
// check below is ANCHORED on main's own preamble section: an unanchored
// pattern would match foo's or bar's plan and assert nothing about THIS TU.
// main is the entry TU, so it has a preamble and no header, and its section
// is the last one in the dump.
// PLAN: ===== EMIT PLAN fid 0 (preamble)

// Tier 0 forward-declares every type in the set, which is what breaks the
// pointer edge to Deep before tier 1 has to sort anything. Membership is the
// assertion here, not order, hence -DAG.
// No `fid N @ off` in any pattern below: the offsets are byte positions in
// these files, and main's own is past THESE COMMENTS, so asserting it would
// break on every edit to the prose.
// PLAN: -- tier 0: forward declarations --
// PLAN-DAG: class ::foo::F [fwd] foreign
// PLAN-DAG: class ::bar::B [fwd] foreign
// PLAN-DAG: class ::bar::Deep [fwd] foreign

// Tier 1 is definitions only, and ORDER is the assertion: B precedes F
// whatever order the two files were written in. -NEXT is what makes that
// exact, and it is also what proves Deep is not wedged between them --
// nothing needs Deep's layout, so it never gets a definition at all.
// PLAN: -- tier 1: definitions --
// PLAN-NEXT: class ::bar::B [complete] foreign
// PLAN-NEXT: class ::foo::F [complete] foreign
// PLAN-NOT: Deep
// PLAN: -- tier 2: function declarations --

// main is this TU's own; use_f is reached through foo. The own/foreign
// column is the point -- a plan that marked either wrongly would emit a
// definition in the wrong object.
// PLAN-DAG: fn ::main [fwd] own
// PLAN-DAG: fn ::foo::use_f [fwd] foreign

// Never named from main, so never in MAIN's plan. It does appear in foo's
// own plan, correctly: a TU plans its own declarations, because the class
// text it emits must be identical to the text every importer emits. That is
// exactly why this check is anchored rather than global -- as a bare
// PLAN-NOT over the whole dump it would now be asserting the opposite of
// the rule. main's section is last, so this runs to end of input.
// PLAN-NOT: Unused
