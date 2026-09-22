// rule: `Lib/std` is registered under the ROOT NAME `kairo::std`, so every
// declaration in it is `kairo::std::…` and emits into `::kairo::std` -- a
// namespace that can never collide with C++'s own `std`. Bare `std` is a
// TU-LOCAL ALIAS the prelude binds (`import kairo::std as std`), not a root
// name, so no import is needed here and nothing in this file spells `kairo`.

fn use_std() -> void {
    std::print(7)
}

// --- lit wiring -----------------------------------------------------------
//
// 1. bare `std` binds with no import, and the decl it reaches lives in
//    `kairo::std` -- not in `std`, and not in `kairo::std::module`, which is
//    what a root's own module.k produced before canonical_module_path learned
//    that at a root's TOP level the `module` leaf names the ROOT.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: kairo::std
//
// 2. BOTH preludes reach an ordinary TU, and they are different shapes:
//    builtin's is a wildcard (every name it declares), std's is an aliased
//    plain import (exactly one name).
// RUN: { %kairo %s --type-check-only --print-imports 2>/dev/null || true; } | %FileCheck %s --check-prefix=IMP
// IMP-DAG: <prelude> import builtin::*
// IMP-DAG: <prelude> import kairo::std as std
//
// 3. the emitted spelling carries the prefix. `::std::print` here would mean
//    kairo's standard library had been emitted into C++'s namespace, which is
//    the collision this whole design exists to make impossible.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: kairo::std
// CXX: print
//
// 4. nothing is diagnosed in the ordinary case.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}} [
//
// 5. --no-stdlib removes the root AND the alias, so bare `std` is an ordinary
//    undeclared name -- the point being that it is a NAME like any other, with
//    no special case anywhere to keep it alive.
// RUN: { %kairo %s --type-check-only --no-stdlib 2>&1 || true; } | %FileCheck %s --check-prefix=NOSTD
// NOSTD: error
// NOSTD-SAME: std
