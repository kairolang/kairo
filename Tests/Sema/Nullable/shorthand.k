// G4 (Compiler/Sema/NULLABLE.md 1.6): `var x? = e` declares `x` with the
// type of `e` made nullable, ONE level: `typeof(e)?`, or `typeof(e)` when
// `e` is already nullable, so `var b? = find()` with `find() -> i32?` is
// `i32?` and not `(i32?)?` (the shorthand says "may be null", it does not
// add a level; a deliberate `(T?)?` is still writable as a type). File
// scope and `const` infer the same way, including a global used before its
// declaration (StmtTyping::var_type's demand path, which must hand back the
// wrapped `i32?`: read_bare's `return early` into `i32` is SC028E). A null
// literal has no type to infer from: SC076E naming the shorthand, for
// `null`, `&null` and a parenthesized `null`, and the binding is poisoned
// so nothing cascades.

struct P { var x: i32 = 1 }

fn find() -> i32? { return 3 }
fn read_early() -> i32? { return early }
fn read_bare() -> i32 { return early }      // early is i32? on the demand path too

var early? = 8
const top? = find()

fn main() -> i32 {
    var a? = 10
    var b? = find()
    var n = 7
    var c? = &n
    var s? = P{}
    var d? = (find())
    var nn? = early
    var plain = 4
    return 0
}

fn errors() {
    var x? = null
    var y? = &null
    const u? = (null)
    var after = x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: early : i32?
// SEMA-DAG: top : i32?
// SEMA-DAG: a : i32?
// SEMA-DAG: b : i32?
// SEMA-DAG: n : i32
// SEMA-DAG: c : *i32?
// SEMA-DAG: s : P?
// SEMA-DAG: d : i32?
// SEMA-DAG: nn : i32?
// SEMA-DAG: plain : i32
// SEMA-NOT: (i32?)?

// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: shorthand.k:17:32: error [SC028E]: cannot convert 'i32?' to 'i32'
// DIAG-NOT: {{error|warning}}
// DIAG: shorthand.k:35:14: error [SC076E]: nothing to infer the nullable's type from: 'x?' takes its type from the initializer, and 'null' has none
// DIAG-NOT: {{error|warning}}
// DIAG: shorthand.k:36:14: error [SC076E]: nothing to infer the nullable's type from: 'y?' takes its type from the initializer, and '&null' has none
// DIAG-NOT: {{error|warning}}
// DIAG: shorthand.k:37:17: error [SC076E]: nothing to infer the nullable's type from: 'u?'
// DIAG-NOT: {{error|warning}}
