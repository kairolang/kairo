// The X half of the builtin errors: one diagnostic per marked line, nothing
// else. See resolve_errors.k for why the two halves are separate files.

fn main() -> i32 {
    var f = __builtin_trap;                       // SC109E: builtin used as a value.
    var g = &__builtin_trap;                      // SC109E: no address either.

    var p = __builtin_alloca(64);
    var align: i32 = 8; var wide: i64 = 8;
    __builtin_coro_promise(p, align, false);      // SC108E: argument 2 must be an integer constant.
    __builtin_coro_promise(p, -8, !true);         // constants under unary operators: accepted.
    __builtin_coro_promise(p, alignof(i64) as i32, false);   // alignof cast to an integer: a constant.
    __builtin_coro_promise(p, sizeof(i64) as i32, true);     // sizeof too.
    __builtin_coro_promise(p, wide as i32, false);           // SC108E: casting a non-constant does not make one.
    return 0;
}

// --- lit wiring (below the code: nothing above shifts a line) -------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:      typing_errors.k:5:13: error [SC109E]: '__builtin_trap' is a clang builtin; it can only be called directly
// DIAG-NEXT: typing_errors.k:6:14: error [SC109E]: '__builtin_trap' is a clang builtin; it can only be called directly
// DIAG-NEXT: typing_errors.k:10:31: error [SC108E]: argument 2 of '__builtin_coro_promise' must be an integer constant
// DIAG-NEXT: typing_errors.k:14:31: error [SC108E]: argument 2 of '__builtin_coro_promise' must be an integer constant
// DIAG-NOT: error
