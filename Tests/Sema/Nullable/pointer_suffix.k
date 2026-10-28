// G1 (Compiler/Sema/NULLABLE.md 1.4): `*T?` is a nullable POINTER,
// `(*T)?`, as nullables.md and pointers.md write it; a pointer TO a
// nullable is spelled `*(T?)`. The parser used to bind the `?` to the
// pointee, so `var p: *i32? = &a` was SC028E and every doc example failed.
// The two types print distinctly in diagnostics.
class A { pub var n: i32 = 1 }

fn keep_np(p: *i32?) -> *i32? = p
fn keep_pn(p: *(i32?)) -> *(i32?) = p
fn keep_obj(p: *A?) -> *A? = p

fn main() -> i32 {
    var a = 42
    var o = A()
    // Happy: an address and null both convert to a nullable pointer, and
    // the parenthesized spelling is the same type.
    var p: *i32? = &a
    var q: *i32? = null
    var r: (*i32)? = &a
    p = r
    q = p
    var po: *A? = &o
    var pp: **i32? = null           // (**i32)?
    var cp: *const i32? = &a        // (*const i32)?
    var x: i32? = 5
    var pn: *(i32?) = &x            // a pointer to a nullable
    var i_np = keep_np(p)
    var i_pn = keep_pn(pn)
    var i_ob = keep_obj(po)
    var i_pp = pp
    var i_cp = cp
    // Errors: the two shapes do not convert into each other.
    var bad1: *(i32?) = &a
    var bad2: *i32? = &x
    var bad3: *i32? = pn
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: error
// DIAG: pointer_suffix.k:33:25: error [SC028E]: cannot convert '*i32' to '*(i32?)'
// DIAG-NOT: error
// DIAG: pointer_suffix.k:34:23: error [SC028E]: cannot convert '*(i32?)' to '*i32?'
// DIAG-NOT: error
// DIAG: pointer_suffix.k:35:23: error [SC028E]: cannot convert '*(i32?)' to '*i32?'
// DIAG-NOT: error

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: -- inferred decls --
// SEMA-DAG: i_np : *i32?
// SEMA-DAG: i_pn : *(i32?)
// SEMA-DAG: i_ob : *A?
// SEMA-DAG: i_pp : **i32?
// SEMA-DAG: i_cp : *const i32?
