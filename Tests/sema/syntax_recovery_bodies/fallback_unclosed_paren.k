// The shape that still falls back. `foo(v,` with the body's `}` on
// the next line: the parse reports the missing `)` once and closes the body
// on that `}`, but counting brackets from the body's `{` the `}` pairs with
// nothing (the `(` is still open), so the body did not end at the brace the
// text pairs with it. --check-past-syntax-errors leaves the file unchecked:
// the healthy function's type error below is not reported.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// RUN: { %kairo %s --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// RUN: { env KAIRO_DEBUG_SYNTAX_RECOVERY=1 %kairo %s --type-check-only --check-past-syntax-errors 2>&1 || true; } | %FileCheck %s --check-prefix=DBG
//
// CHECK: fallback_unclosed_paren.k:18:8: error [S054E]: expected ')' to close function call argument list
// DBG: syntax-recovery: entry skipped

fn foo(a: i32, b: i32) -> i32 { return a }

fn broken(v: i32) -> i32 {
    foo(v, 
}

fn below(v: i32) -> i32 {
    var z: i32 = "not checked"
    return v
}
