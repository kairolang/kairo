// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only -- the two-phase-lookup and
// `typename`/`template` disambiguator machinery that most of clang's
// SemaTemplate dependent-name suite is ABOUT is explicitly out of scope
// per the task brief; what's ported is the observable OUTCOME those tests
// check for, restated for Kairo's actual model):
//   Lib/llvm-runtimes/clang/test/SemaTemplate/ (dependent-name shape only)
//
// RESOLUTION.md hard invariant #5: "Dependent = deferred, not failed.
// Marked and skipped by N/T/CB; M2 owns it." This file proves that a name
// rooted in a generic parameter -- `T::Item`, `x.thing` where `x: T`, a
// `self`-typed return inside a generic class -- is neither an error NOR
// silently dropped: it is explicitly recorded as Dependent (member steps)
// or resolves to a dependent GenericParamType / Self-record (type nodes),
// and NOTHING here is diagnosed. Also covers the one case that DOES bind
// concretely even inside a generic body: a FUNCTION's own `<T>` is pushed
// into N's lexical stack (RESOLUTION.md §2.5(b): only a function's generic
// params are, today -- a class's are not, see typeres_class_generic_expr.k
// for that documented gap), so `T` used as a plain type name resolves.
//
// Dropped entirely: two-phase lookup ordering (when a dependent name is
// looked up at definition vs instantiation), `typename`/`template`
// disambiguators (no Kairo grammar ambiguity to disambiguate -- `::` after
// a generic param is unconditionally treated as a scope step and marked
// Dependent, per TypeResolve.k's `isa::<GenericParamDecl>(cur)` check),
// SFINAE, and partial ordering of specializations (all need
// OverloadResolution / M1/M2, [MISSING]).

// ---------------------------------------------------------------------------
// CASE 1: `T::Item` in TYPE position, `self.val.thing` (rooted in `T`) in
// VALUE position, inside a generic class method. Both are dependent, both
// deferred -- neither is an error.

class <T> Box {
    var val: T;

    fn get(self) -> T::Item {
        return self.val.thing
    }

    // ------------------------------------------------------------------
    // CASE 2: `Self` as a return type inside a generic class denotes
    // `Box<T>` with the class's OWN params as args -- dependent by
    // construction (RESOLUTION.md §2.6: "Generic enclosing type: Self is
    // Foo<T...>, dependent."), not an error, and the body's `self` is
    // ordinary (non-dependent) binding since `self`'s declared type is
    // just "the enclosing type", resolved concretely by N/T regardless of
    // T's own dependence.
    fn identity(self) -> Self {
        return self
    }
}

// ---------------------------------------------------------------------------
// CASE 3: a FUNCTION's own generic parameter resolves as an ordinary type
// name inside its body (contrast with the class case: RESOLUTION.md
// §2.5(b) says only a function's generic params are in N's lexical stack
// today). `T::Item` here is dependent for the same reason as CASE 1, but
// the FACT that `T` itself binds (rather than reporting "undeclared") is
// what this case is actually proving.

fn <T> generic_fn(x: T) -> T::Item {
    return x.thing
}

// --- diagnostics: none of this is an error ------------------------------
// DIAG-NOT: error
// DIAG-NOT: undeclared identifier
// DIAG-NOT: no member named

// --- bindings ----------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}typeres_dependent.k =====

// CASE 1: both steps recorded Dependent, not bound and not errored.
// SEMA:      fn Box::get  @
// SEMA:        member  .val  {{.*}}<dependent: rooted in a generic parameter   M2>
// SEMA-NEXT:   member  .thing  {{.*}}<dependent: rooted in a generic parameter   M2>

// CASE 2: `self` binds ordinarily even though its declared type (Self) is
// dependent. Frame 1, not 0: a generic TYPE scope pushes a frame of its own
// for `T` (so `T` is visible in expression position inside the body), and the
// method's params nest inside it.
// SEMA:      fn Box::identity  @
// SEMA:        use     self  {{.*}} -> param self {{.*}}  [local frame 1]

// CASE 3: `T` is a real declared generic in the function's frame (not
// "undeclared"); `x` binds to the param; the dependent chain step off it
// is deferred, not errored.
// SEMA:      fn generic_fn  @
// SEMA:        declare T           = generic T {{.*}}
// SEMA:        use     x       {{.*}} -> param x {{.*}}  [local frame 0]
// SEMA-NEXT:   member  .thing  {{.*}}<dependent: rooted in a generic parameter   M2>

// The whole-file type tally: some canonical (Box, i32-free here), the rest
// legitimately dependent -- never "poisoned".
// SEMA: type node(s): {{[0-9]+}} canonical, {{[1-9][0-9]*}} dependent
