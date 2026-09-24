// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/CXX/basic/basic.lookup/basic.lookup.classref/
//   (typedef-name-as-type-specifier half)
//   Lib/llvm-runtimes/clang/test/SemaTemplate/template-default-param-through-using.cpp
//   (generic-alias-application half only; the "through a `using` alias
//   TEMPLATE" mechanics are C++-specific, but "an alias applied with
//   generic arguments expands and member lookup passes through it" is the
//   same shape as Kairo's `type <T> Name = ...`)
//
// What this proves, all TypeResolution (phase T) territory per
// RESOLUTION.md §2.6's "Aliases expand on demand through `_expand_alias`":
//   - a plain (non-generic) alias expands to its target's canonical, and
//     member lookup through the alias reaches the target's members;
//   - alias chains (an alias of an alias) expand transitively;
//   - a MODULE-qualified alias (`M::Local`) resolves the SAME way;
//   - a GENERIC alias applied with arguments (`WrapAlias<i32>`) expands
//     and members are still reachable;
//   - misuse is diagnosed at the alias, not the target: applying generic
//     arguments to a NON-generic alias, and an unknown type name entirely.
//
// Dropped: alias through `using Name = ...` C++ syntax (Kairo's alias
// syntax is `type Name = ...` uniformly, no separate using-alias form to
// distinguish), dependent alias template specialization (needs M2,
// [MISSING] per RESOLUTION.md §2.9 -- covered separately, as a deferred
// case rather than an error, by typeres_dependent.k).

class Point {
    var x: i32;
}

// ---------------------------------------------------------------------------
// CASE 1: plain alias, one hop. Member lookup through `P` reaches `Point`'s
// field.

type P = Point;

fn use_alias(p: P) -> i32 { return p.x }

// ---------------------------------------------------------------------------
// CASE 2: alias of an alias. `PP` -> `P` -> `Point`, expanded transitively;
// `.x` still resolves.

type PP = P;

fn use_alias_chain(p: PP) -> i32 { return p.x }

// ---------------------------------------------------------------------------
// CASE 3: an alias declared INSIDE a module, used through a `::`-qualified
// path. The alias expands in ITS OWN scope (the module's), not the use
// site's -- RESOLUTION.md's `_expand_alias` note: "Resolve in the ALIAS's
// scope, not the use site's."

module M {
    class Inner { var v: i32; }
    type Local = Inner;
}

fn use_module_alias(m: M::Local) -> i32 { return m.v }

// ---------------------------------------------------------------------------
// CASE 4: a GENERIC alias, applied with a CONCRETE argument. T arity-checks
// the application and marks it instantiation-dependent rather than an
// error (RESOLUTION.md §2.6: "Generic alias APPLICATION needs substitution
// of the aliased body -- M2's machinery... hand off as instantiation-
// dependent. Not an error."). Substitution itself is M2, [MISSING] per
// §2.9, so `.val` through `WrapAlias<i32>` is NOT yet bound to the field --
// it is correctly deferred (NeedsInference), never diagnosed as a missing
// member. That is the observable, spec-compliant shape of the gap: no
// false error, just no answer yet.

class <T> Wrapper {
    var val: T;
}

type <T> WrapAlias = Wrapper<T>;

fn use_generic_alias(w: WrapAlias<i32>) -> i32 { return w.val }

// ---------------------------------------------------------------------------
// CASE 5 (negative): applying generic arguments to a NON-generic alias is
// an error at the USE, naming the alias's own declaration as the note.

type NonGeneric = Wrapper<i32>;

fn bad_alias_args(x: NonGeneric<i32>) -> i32 { return 0 }

// ---------------------------------------------------------------------------
// CASE 6 (negative): a type name that resolves nowhere at all.

fn unknown_type_name(x: NoSuchType) -> i32 { return 0 }

// --- expected diagnostics ---------------------------------------------
// DIAG: type alias 'NonGeneric' is not generic and takes no arguments
// DIAG-NEXT: note{{.*}}: declared here
// DIAG: unknown type name 'NoSuchType'
//
// The five positive cases above must not error.
// DIAG-NOT: unknown type name 'P'
// DIAG-NOT: unknown type name 'PP'
// DIAG-NOT: unknown type name 'Local'
// DIAG-NOT: unknown type name 'WrapAlias'
// DIAG-NOT: no member named 'x'
// DIAG-NOT: no member named 'v'
// DIAG-NOT: no member named 'val'

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}typeres_alias_basic.k =====

// CASE 1: member through a one-hop alias.
// SEMA:      <tu>::use_alias
// SEMA:        .x  {{.*}} -> field x {{.*}}

// CASE 2: member through a two-hop alias chain.
// SEMA:      <tu>::use_alias_chain
// SEMA:        .x  {{.*}} -> field x {{.*}}

// CASE 3: member through a module-qualified alias.
// SEMA:      <tu>::use_module_alias
// SEMA:        .v  {{.*}} -> field v {{.*}}

// CASE 4: member through a generic alias application is deferred, not
// bound and not an error (M2's substitution is [MISSING]; see the CASE 4
// comment above).
// SEMA:      <tu>::use_generic_alias
// SEMA:        .val  {{.*}} <open: inference or M2>{{.*}}

// CASE 5/6 are poisoned, not unresolved-and-undiagnosed; their param names
// are declared but never used, so they contribute no rows to name bindings.
