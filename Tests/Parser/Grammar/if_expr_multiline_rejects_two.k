// A value arm holds exactly one expression. Two expressions inside the removed
// braced spelling are still rejected: S073E with no fix-it (there is no single
// value to move behind `=>`) and a note pointing at the statement forms.
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=ERR
// ERR: if_expr_multiline_rejects_two.k:9:28: error [S073E]: value arms are written '=> expr'; '{ }' arms are statement-only
// ERR-NEXT: note [I900N]: multi-statement arms are statement-only
// ERR-NOT: error
fn Test(a: usize) -> i32 {
    var x: i32 = if a <= 8 {
        g()
        h()
    } else => 2
    return x
}
