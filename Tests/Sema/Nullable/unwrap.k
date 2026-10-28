// G10 (Compiler/Sema/NULLABLE.md 2.6): `unwrap!(x)` typed. Each `t_*`
// initializes a `bool` from one so the conversion error names its type:
// `T` for `T?`, one level for `(i32?)?`, `*i32` for `(*i32)?`, `T` for a
// generic `T?`. It is not a read of `x` (no check needed), and afterwards
// `x` is non-null (on null the program ended): `x + 1` after `var v =
// unwrap!(x)` needs no check. It is no panic site: a plain function with
// no `panic` specifier and no `try` uses it. A place unwraps to an lvalue
// (`unwrap!(f).v = 4`). Errors: a non-nullable operand (SC001E, fix-its
// removing `unwrap!(` and `)`); the grammar's are in
// Parser/Grammar/unwrap_intrinsic.k. The loop pre-scan knows `unwrap!(e)`
// is a value.

class Foo { pub var v: i32 = 1 }
fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn nest() -> (i32?)? { return null }

fn t_value(x: i32?)    { var r: bool = unwrap!(x) }
fn t_nested()          { var r: bool = unwrap!(nest()) }
fn t_ptr(p: (*i32)?)   { var r: bool = unwrap!(p) }
fn <T> t_generic(t: T?) -> T { return unwrap!(t) }

fn ok_after(x: i32?) -> i32 {
    var v = unwrap!(x)
    return v + x
}
fn ok_lvalue(f: Foo?) { unwrap!(f).v = 4 }

fn ok_loop(k: i32) -> i32 {
    var x: i32? = 1
    var r = 0
    while r < k {
        r += x
        x = unwrap!(find(r))
    }
    return r
}

fn e_plain(n: i32) -> i32 { return unwrap!(n) }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-errors=0 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: unwrap.k:15:20: warning [S055W]: nested nullable
// DIAG-NOT: {{error|warning}}
// DIAG: unwrap.k:17:40: error [SC028E]: cannot convert 'i32' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: unwrap.k:18:40: error [SC028E]: cannot convert 'i32?' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: unwrap.k:19:40: error [SC028E]: cannot convert '*i32' to 'bool'
// DIAG-NOT: {{error|warning}}
// DIAG: unwrap.k:38:36: error [SC001E]: 'n' is not nullable ('i32'); 'unwrap!' takes a nullable, and this value is never null
// DIAG-NEXT: fix-it:{{.*}}:{38:36-38:44}:""
// DIAG-NEXT: fix-it:{{.*}}:{38:45-38:46}:""
// DIAG-NEXT: unwrap.k:38:12: note [{{.*}}]: 'n' is declared 'i32' here
// DIAG-NOT: {{error|warning}}
