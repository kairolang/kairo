// RUN: { %kairo %s --type-check-only --cmax-macro-expansions=200 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=budget
//
// Mutual recursion is detected as CYCLIC, not left to exhaust the expansion
// budget.
//
// This is the case the chain actually matters for: `pp!` never sees ITSELF in
// one step, only `qq!`, so detecting it needs the chain to carry both hops.
// Both bodies are a single tail invocation, so `pp!`'s frame is exhausted and
// popped before `qq!`'s body is walked: the live frame stack (`inv.chain`)
// holds only `qq` when `pp!` comes round again. `_expand` also checks the
// origin chain captured at detection (`inv.parent_chain`), which keeps popped
// ancestors. Tests/Preprocessor/tail_mutual_recursion.k is the uncapped
// variant (the fuzzer's hang).
//
// The budget cap in the RUN line keeps the failure mode fast if it regresses.
// DIAG: error [R008E]: cyclic expansion of macro 'pp!'
// DIAG: recursion occurs here, in the macro body

macro pp!() { qq!() }
macro qq!() { pp!() }
var a = pp!();
