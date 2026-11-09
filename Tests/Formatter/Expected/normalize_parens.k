// RUN: %kfmt --normalize-parens --stdout %s | diff -u %S/Expected/normalize_parens.k -
// RUN: %kfmt --normalize-parens --check %S/Expected/normalize_parens.k
// RUN: %kfmt --stdout %s | diff -u %S/Expected/normalize_parens_off.k -
//
// Rule 9.5: under --normalize-parens a pair that does not change how the
// expression parses (Stage 1 precedence) goes; a needed pair stays; none is
// added. Without the flag every pair stays.

fn f(a: bool, b: bool, p: *i32, x: i32) {
    if !a && b {
        *p += x
    }

    var t = x * 2 + 1
    var u = !(a == b)
    var v = x - (x - 1)
    var w = x - 1 - x
    var z = (x)
}
