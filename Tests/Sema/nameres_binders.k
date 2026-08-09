// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Statement-level binders bind (phase N). Each of these introduces a name
// through a `Binding` / `CatchArm` / `BindingPattern` rather than a DeclStmt,
// so the parser synthesizes a VariableDecl per binder and N pushes it onto the
// lexical stack. Before that existed, every one of these bodies reported
// `use of undeclared identifier` on its own binder.
//
// Kept separate from name_resolution.k so that file's hardcoded line numbers
// stay stable.

var shadow: i32 = 1;

// Ranged for: `x` is visible in the body only.
fn f_for(xs: *i32) -> i32 {
    var total: i32 = 0;
    for x in xs { total = total + x; }
    return total
}

// A binder shadows a file-scope name of the same spelling.
fn f_shadow(xs: *i32) -> i32 {
    for shadow in xs { return shadow }
    return 0
}

// `case var n` is a real BindingPattern and binds. (A BARE `case n` is an
// UnresolvedConstructorPattern -- ambiguous between a nullary ctor and a
// binder until the scrutinee type exists -- and stays deferred to T.)
fn f_match(v: i32) -> i32 {
    match v {
        case var n { return n }
    }
    return 0
}

// Tuple destructuring declares into the ENCLOSING frame, not a new scope.
fn f_destructure(t: i32) -> i32 {
    var (a, b) = t;
    return a + b
}

// The caught error is a declaration scoped to its arm.
fn f_catch() -> i32 {
    try { return 1 } catch e { return e }
}

// --- no diagnostics at all -------------------------------------------------
// DIAG-NOT: error
// DIAG-NOT: undeclared identifier
// The invariant verifier must not fire either.
// DIAG-NOT: survived name resolution unbound

// --- each binder use resolves to its binder's decl -------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}nameres_binders.k =====

// for-loop variable: bound to the binder at 18:9, not reported unresolved.
// SEMA:      <tu>::f_for
// SEMA:        x  @ 18:35  -> var x @ 18:9

// the binder wins over the file-scope `shadow` at 13:1.
// SEMA:      <tu>::f_shadow
// SEMA:        shadow  @ 24:31  -> var shadow @ 24:9

// SEMA:      <tu>::f_match
// SEMA:        n  @ 33:29  -> var n @ 33:14

// SEMA:      <tu>::f_destructure
// SEMA:        a  @ 41:12  -> var a @ 40:10
// SEMA-NEXT:   b  @ 41:16  -> var b @ 40:13

// SEMA:      <tu>::f_catch
// SEMA:        e  @ 46:39  -> var e @ 46:28

// Nothing anywhere in the file is left unbound.
// SEMA:      0 unresolved
