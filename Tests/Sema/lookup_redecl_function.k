// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/function-redecl.cpp
//   Lib/llvm-runtimes/clang/test/SemaCXX/function-overloaded-redecl.cpp
//
// clang's function-redecl.cpp is mostly about the "differ only in return
// type" rule, which needs full signature comparison (OverloadResolution)
// and is explicitly [MISSING] in RESOLUTION.md §2.5(a): "telling a
// redeclaration from an overload needs signatures. Deferred to
// OverloadResolution." What N(a) DOES do today, and what this file proves,
// is the boundary of that deferral: EVERY group of same-name FunctionDecls
// in one cell is treated as a legitimate, undifferentiated overload set --
// `all_fn { return; }` in `_validate_cell` -- regardless of arity or
// whether two signatures are byte-for-byte identical. That is intentional
// (documented [MISSING], not a bug): only actual TYPE mismatches on a call
// are OverloadResolution's job, and OverloadResolution does not exist yet.
// So CASE 2 here (two IDENTICAL signatures) asserts NO diagnostic, which
// looks surprising until you read it as "this is the deferred gap, exactly
// as wide as the doc says it is."
//
// Also ported: a function name in a nested MODULE does not collide with
// the same spelling at file scope (function-redecl.cpp's per-namespace
// redeclaration story, without the return-type-overload half).
//
// Dropped: local (function-body-nested) redeclarations -- clang's `f2`
// nested-block cases -- because return-type-overload detection is the
// exact machinery being dropped, and there is nothing else left to port
// there; ADL-found overloads (no Kairo ADL).

// ---------------------------------------------------------------------------
// CASE 1: two arities under one name. N hands the WHOLE cell through as a
// 2-candidate set; it does not and cannot select (needs argument types).

fn overloaded(a: i32) -> i32 { return a }
fn overloaded(a: i32, b: i32) -> i32 { return a }

fn use_overloaded() -> i32 {
    return overloaded(1)
}

// ---------------------------------------------------------------------------
// CASE 2: two decls with the IDENTICAL signature. This is not diagnosed by
// N -- redecl-vs-overload needs signature comparison, which is
// OverloadResolution's job and does not exist yet. Using it lands the same
// 2-candidate set CASE 1 got.

fn exact_dup(a: i32) -> i32 { return a }
fn exact_dup(a: i32) -> i32 { return a + 1 }

fn use_exact_dup() -> i32 {
    return exact_dup(1)
}

// ---------------------------------------------------------------------------
// CASE 3: a module-scoped function does not collide with a file-scope
// function of the same spelling and different arity; each name resolves
// in its OWN scope independently.

module N {
    fn helper(x: i32) -> i32 { return x }
}

fn helper(x: i32, y: i32) -> i32 { return x + y }

fn use_module_and_file() -> i32 {
    return N::helper(1) + helper(1, 2)
}

// --- diagnostics -------------------------------------------------------
// Every one of these is legal today (the redecl/overload distinction is
// deferred, not enforced as an error).
// DIAG-NOT: error
// DIAG-NOT: redefinition
// DIAG-NOT: undeclared identifier

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}lookup_redecl_function.k =====

// The "multi-decl names" section lists cells ALPHABETICALLY, not in source
// order, so `exact_dup` (CASE 2) is dumped before `overloaded` (CASE 1).

// CASE 2: the identical-signature pair survives as an undifferentiated
// 2-candidate set -- the documented gap, not a chain merge.
// SEMA:      <tu>::exact_dup   [overload set x2]
// SEMA-NEXT:   - fn exact_dup @ 49:1  [definition]
// SEMA-NEXT:   - fn exact_dup @ 50:1  [definition]

// CASE 1: both arities survive as one 2-candidate overload set.
// SEMA:      <tu>::overloaded   [overload set x2]
// SEMA-NEXT:   - fn overloaded @ 36:1  [definition]
// SEMA-NEXT:   - fn overloaded @ 37:1  [definition]

// CASE 1's use: 2 candidates, deferred.
// SEMA:      overloaded  {{.*}} -> 2 candidate(s), awaiting overload resolution
// SEMA-NEXT:     - fn overloaded @ 36:1
// SEMA-NEXT:     - fn overloaded @ 37:1

// CASE 2's use: same shape.
// SEMA:      exact_dup  {{.*}} -> 2 candidate(s), awaiting overload resolution
// SEMA-NEXT:     - fn exact_dup @ 49:1
// SEMA-NEXT:     - fn exact_dup @ 50:1

// CASE 3: the module's `helper` and the file-scope `helper` are two
// distinct, independently-bound single-candidate names -- no interaction.
// SEMA:      <tu>::use_module_and_file
// SEMA:        N  {{.*}} -> module N {{.*}}
// SEMA-NEXT:   ::helper  {{.*}} -> fn helper @ 62:5
// SEMA-NEXT:   helper  {{.*}} -> fn helper @ 65:1  [scope <tu>]

// Nothing left unbound; both overload sets stay deferred rather than
// unresolved.
// SEMA: 0 unresolved
