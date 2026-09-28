// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// Statement expression `({ s...; e })`: a prvalue of `e`, typed after the
// leading statements. Checks sit below the code: they name line:col.

fn get() -> i32 { return 4 }
fn noth() { }

fn Good() -> i32 {
    var a = ({ var t = 1; t * 2 })
    var b: u8 = ({ 5 })
    var c = ({
        var u = get()
        if u > 2 { return 0 }
        u + a
    })
    const k: i32 = 3
    var d = ({ k })
    ({ noth() })
    return a + c + d + (b as i32)
}

fn Bad() {
    var s: string = ({ 5 })
    var arr: [i32; 2] = [1, 2]
    var x = ({ arr })
}

// `a`: the local `t` is typed before the value reads it.
// `b`: the expected type reaches the value, so the literal is u8 and not an
//      i32 narrowed afterwards.
// `c`: a `return` inside the block targets the enclosing function.
// `d`: top-level const drops off a prvalue.
// `noth()`: a void value is allowed; the expression is just void.
// Anchored on `get`'s literal: every TU prints its own types section, and
// the prelude's come first.
// SEMA: <tu>::get
// SEMA-NEXT: IntegerLiteralExpr @ 6:26
// SEMA-DAG: StmtExpr @ 10:13 : i32
// SEMA-DAG: IntegerLiteralExpr @ 11:20 : u8
// SEMA-DAG: StmtExpr @ 11:17 : u8
// SEMA-DAG: StmtExpr @ 12:13 : i32
// SEMA-DAG: StmtExpr @ 18:13 : i32
// SEMA-DAG: StmtExpr @ 19:5 : void
//
// DIAG: stmt_expr.k:24:21: error [SC001E]: cannot convert 'i32' to 'string'
// DIAG: stmt_expr.k:26:13: error [SC001E]: a statement expression cannot yield an array ('[i32; 2]'); an array is not copied implicitly
// DIAG-NOT: error
