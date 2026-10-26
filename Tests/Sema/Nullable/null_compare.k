// G6 (Compiler/Sema/NULLABLE.md 2.2): `x == null`, `null == x`,
// `x != null` and `null != x` are the null test spelled differently, typed
// `bool` on any nullable, the literal taking the nullable's type. `&null`
// against a nullable POINTER is that nullable's null (1.3), so `q == &null`
// is the same test; against an `i32?` it is the literal's own SC076E (a
// pointer null where no pointer is). Against a value that cannot be null
// the comparison could only be false, and is an error, SC001E, raised
// before the literal is typed (it used to be SC076E "cannot infer the type
// of 'null'", which hid the real mistake): a primitive, a literal, a safe
// pointer, each with a note at the declaration when it is a name. A raw
// pointer CAN be null, but its null is `&null`: the error says so and the
// fix-it rewrites the literal; `raw == &null` stays a pointer comparison.

fn find() -> i32? { return 3 }

fn main() -> i32 {
    var n = 4
    var p = &n
    var raw: unsafe *i32 = unsafe &n
    var a = find()
    var q: (*i32)? = &n
    var t1 = a == null
    var t2 = null == a
    var t3 = a != null
    var t4 = null != (a)
    var t5 = q == &null
    var t6 = &null != q
    var t7 = q == null
    var t8 = raw == &null
    var e1 = 5 == null
    var e2 = n != null
    var e3 = null == p
    var e4 = raw == null
    var e5 = a == &null
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error [
// DIAG: null_compare.k:30:14: error [SC001E]: the operand is not nullable; 'i32' is never null, so comparing it with 'null' is meaningless
// DIAG-NOT: error [
// DIAG: null_compare.k:31:14: error [SC001E]: 'n' is not nullable; 'i32' is never null, so comparing it with 'null' is meaningless
// DIAG-NEXT: null_compare.k:17:5: note [{{.*}}]: declared 'i32' here; a type that may be null is written 'T?'
// DIAG-NOT: error [
// DIAG: null_compare.k:32:14: error [SC001E]: 'p' is not nullable; '*i32' is never null, so comparing it with 'null' is meaningless
// DIAG-NEXT: null_compare.k:18:5: note
// DIAG-NOT: error [
// DIAG: null_compare.k:33:14: error [SC001E]: 'raw' is a raw pointer, not a nullable; a raw pointer's null is '&null'
// DIAG-NEXT: fix-it:{{.*}}:{33:21-33:25}:"&null"
// DIAG-NOT: error [
// DIAG: null_compare.k:34:19: error [SC076E]: cannot infer the pointer type of '&null' here
// DIAG-NOT: error [

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: t1 : bool
// SEMA-DAG: t2 : bool
// SEMA-DAG: t3 : bool
// SEMA-DAG: t4 : bool
// SEMA-DAG: t5 : bool
// SEMA-DAG: t6 : bool
// SEMA-DAG: t7 : bool
// SEMA-DAG: t8 : bool
