// RUN: { %kairo %s --type-check-only --cmax-macro-expansions=200 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// XFAIL: *
//
// BUG: mutual recursion is not detected as cyclic either -- same cause as
// self_recursion.k (the invocation chain arrives empty, so `_expand`'s cycle
// check never matches). It falls through to the expansion budget.
//
// This is the case the chain actually matters for: `pp!` never sees ITSELF in
// one step, only `qq!`, so detecting it needs the chain to carry both hops.
// A fix that special-cases direct self-recursion will pass self_recursion.k
// and leave this one failing.
//
// The budget cap in the RUN line keeps the test fast; see self_recursion.k.
//
// Today, with the cap: "macro expansion budget exhausted".
// DIAG: error [R008E]: cyclic expansion of macro 'pp!'
// DIAG: recursion occurs here, in the macro body

macro pp!() { qq!() }
macro qq!() { pp!() }
var a = pp!();
