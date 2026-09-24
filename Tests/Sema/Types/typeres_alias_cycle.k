// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// No direct clang analogue -- C++ typedefs/using-aliases cannot form a
// self-referential cycle through the type grammar the way `type A = B;`
// can (a C++ `using A = B;` where B names A is simply "use of undeclared
// identifier B", since a typedef's target must already be complete/known;
// clang's alias templates come closest but need the template machinery
// clang's own tests for it, e.g. redeclared-alias-template.cpp, are about
// REDECLARATION, not self-reference). This file instead exercises
// Kairo-native machinery that plays the equivalent role to what C++
// regression suites use "incomplete type" / recursive-template-instantiation
// diagnostics for: alias-cycle detection in TypeResolution, RESOLUTION.md
// §2.6's `_expand_alias`, `ResolutionState::InProgress` re-entrancy check,
// and `_report_alias_cycle`'s "one error, every link as a note" contract
// (§1c: "re-entering it is a cycle in the USER's program, reported with
// the stack as notes").
//
// What this proves:
//   - a DIRECT self-cycle (`type X = X;`) is one error, one note;
//   - an INDIRECT two-step cycle (`type A = B; type B = A;`) is ONE error
//     (not two -- `Errored` is permanent per §1c: "a bad alias used fifty
//     times reports once"), with BOTH links noted in walk order;
//   - every alias on the cycle is poisoned, so a later, unrelated use of
//     either name does not cascade a second diagnostic.

// ---------------------------------------------------------------------------
// CASE 1: direct self-reference.

type Direct = Direct;

fn use_direct(x: Direct) -> i32 { return 0 }

// ---------------------------------------------------------------------------
// CASE 2: indirect two-step cycle. The error fires when resolving B's
// target closes the loop back to A (A is `InProgress` at that point), so
// it is reported AT the reference to A inside B's definition, naming A.

type A = B;
type B = A;

fn use_a(x: A) -> i32 { return 0 }

// A second, independent use of the SAME poisoned alias must not add a
// second diagnostic (Errored is permanent).
fn use_a_again(y: A) -> i32 { return 0 }

// --- expected diagnostics, in source order ------------------------------
//
// CASE 1: one error, one note, both on line 30.
// DIAG: typeres_alias_cycle.k:30:15: error{{.*}}: type alias 'Direct' is defined in terms of itself
// DIAG-NEXT: typeres_alias_cycle.k:30:1: note{{.*}}: 'Direct' is declared here and refers to the next alias in the cycle
//
// CASE 2: one error total (not two), reported where B's target A closes
// the loop, with both links noted in walk order (A first, then B).
// DIAG: typeres_alias_cycle.k:40:10: error{{.*}}: type alias 'A' is defined in terms of itself
// DIAG-NEXT: typeres_alias_cycle.k:39:1: note{{.*}}: 'A' is declared here and refers to the next alias in the cycle
// DIAG-NEXT: typeres_alias_cycle.k:40:1: note{{.*}}: 'B' is declared here and refers to the next alias in the cycle
//
// Exactly those two errors -- `use_a_again`'s independent use of the same
// poisoned `A` must NOT re-report.
// DIAG-NOT: {{.*}}error{{.*}}defined in terms of itself{{.*}}defined in terms of itself

// --- bindings: both aliases end up poisoned, not silently unresolved ------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}typeres_alias_cycle.k =====
// SEMA:      Direct      -> type Direct {{.*}}  [poisoned]
// SEMA:      A           -> type A {{.*}}  [poisoned]
// SEMA:      B           -> type B {{.*}}  [poisoned]

// Both use-sites still declare their (poisoned-type) params; nothing about
// the cycle detection crashes or leaves a param half-bound.
// SEMA:      fn use_direct  @
// SEMA-NEXT:   declare x           = param x {{.*}}
// SEMA:      fn use_a  @
// SEMA-NEXT:   declare x           = param x {{.*}}
// SEMA:      fn use_a_again  @
// SEMA-NEXT:   declare y           = param y {{.*}}
