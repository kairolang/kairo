// RUN: { %kairo %s --type-check-only --cmax-macro-expansions=200 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// Direct self-recursion is detected as CYCLIC, not left to exhaust the
// expansion budget.
//
// PPWalker::_expand walks `inv.chain` looking for the macro's own symbol.
// This was XFAIL while that chain arrived EMPTY for a body that IS the
// invocation: the parent splice frame was already exhausted and popped by the
// time the nested invocation was detected, so the guard never fired and the
// only symptom was a budget-exhausted error a minute later. TokenSource.k
// documents that hazard on `SpliceFrame::chain`.
//
// It started passing when the prelude landed -- every TU now imports builtin,
// which changes what is on the splice stack when the macro expands, so the
// chain is no longer empty at the point of the check. That is a real fix in
// effect but an incidental one in cause: if this ever regresses, the guard
// itself is what needs the repair, not this test.
//
// The budget cap in the RUN line keeps the failure mode fast if it does
// regress; it is not needed for the passing path.
// DIAG: error [R008E]: cyclic expansion of macro 'boom!'
// DIAG: note{{.*}}recursion occurs here, in the macro body

macro boom!() { boom!() }
var a = boom!();

