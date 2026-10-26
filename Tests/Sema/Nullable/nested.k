// NULLABLE.md 1.5 (G3): `(T?)?` is a type of its own, Nullable<Nullable<T>>,
// never collapsed to `T?`. Written by hand it is warned about (S055W, with
// a note: outside generic code it is usually a mistake) and kept nested;
// reached by substitution (`V?` with `V = i32?`) it is the same nested
// type, silently. A value becomes present in ONE `?`: `T -> (T?)?` is two
// wraps and does not convert, `T? -> (T?)?` wraps the whole nullable, and
// `null` is the outer null. The printers write the nesting as `(i32?)?`,
// the only spelling that parses back (`i32??` is the `??` operator).

fn <V> wrap(v: V) -> V? { return v }

fn main() -> i32 {
    var outer: (i32?)? = null       // warned; the outer null
    var inner: i32? = 1
    var whole: (i32?)? = inner      // warned; i32? -> (i32?)? wraps it
    var w? = wrap(inner)             // (i32?)? by substitution, no warning
    var c? = wrap(5)                 // i32?, one level
    var bad: (i32?)? = 5            // warned; i32 -> (i32?)? is two wraps
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: nested.k:13:22: warning [S055W]: nested nullable '(T?)?': legal and distinct from 'T?', but rarely what you want
// DIAG-NEXT: nested.k:13:17: note [I900N]: outside generic code this is usually a mistake; a single '?' is one level of null
// DIAG-NOT: {{error|warning}}
// DIAG: nested.k:15:22: warning [S055W]: nested nullable
// DIAG-NOT: {{error|warning}}
// DIAG: nested.k:18:20: warning [S055W]: nested nullable
// DIAG-NOT: {{error|warning}}
// DIAG: nested.k:18:24: error [SC028E]: cannot convert 'i32' to '(i32?)?'
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: w : (i32?)?
// SEMA-DAG: c : i32?
