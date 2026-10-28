// G5 (Compiler/Sema/NULLABLE.md 2.1): `x?` tests a nullable, and nothing
// else. On a non-nullable value -- a primitive, a safe or raw pointer, a
// record, a call's result -- it is SC066E (no operator for this operand
// type) naming the operand, with a note at the declaration that made it
// non-nullable when the operand is a name. The node is poisoned, so the
// condition it sits in reports nothing further. On a nullable it is `bool`
// (--print-sema: `ok` and `nn` infer bool), including `(i32?)?` and a
// generic `T?`; a bare `t?` on a generic `T` is the same SC066E (MONO.md D0).

struct P { var x: i32 = 1 }

fn find() -> i32? { return 3 }
fn two() -> i32 { return 2 }
fn <T> later(t: T) -> i32 { if t? { return 1 } return 0 }

fn main() -> i32 {
    var n = 4
    var p = &n
    var s = P{}
    var f = find()
    var ok = f?
    var nested: (i32?)? = f
    var nn = nested?
    if n? { return 1 }
    if p? { return 2 }
    if s? { return 3 }
    if two()? { return 4 }
    var b = (n)?
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error [
// DIAG: null_test_errors.k:14:32: error [SC066E]: 't' is not nullable; '?' tests a nullable, and 'T' is never null
// DIAG-NOT: error [
// DIAG: null_test_errors.k:24:8: error [SC066E]: 'n' is not nullable; '?' tests a nullable, and 'i32' is never null
// DIAG-NEXT: null_test_errors.k:17:5: note [{{.*}}]: declared 'i32' here; a type that may be null is written 'T?'
// DIAG-NOT: error [
// DIAG: null_test_errors.k:25:8: error [SC066E]: 'p' is not nullable; '?' tests a nullable, and '*i32' is never null
// DIAG-NEXT: null_test_errors.k:18:5: note
// DIAG-NOT: error [
// DIAG: null_test_errors.k:26:8: error [SC066E]: 's' is not nullable; '?' tests a nullable, and 'P' is never null
// DIAG-NOT: error [
// DIAG: null_test_errors.k:27:8: error [SC066E]: the operand is not nullable; '?' tests a nullable, and 'i32' is never null
// DIAG-NOT: error [
// DIAG: null_test_errors.k:28:14: error [SC066E]: 'n' is not nullable
// DIAG-NOT: error [

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: ok : bool
// SEMA-DAG: nn : bool
