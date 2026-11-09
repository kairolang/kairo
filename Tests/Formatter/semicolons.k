// RUN: %kfmt --stdout %s | diff -u %S/Expected/semicolons.k -
// RUN: %kfmt --check %S/Expected/semicolons.k
// RUN: not %kfmt --check %s > %t.out
// RUN: grep -q "semicolons.k" %t.out
//
// Rules 13.1-13.3 and 8.12: a `;` that only ends a line goes; two
// statements on one line are split; a `;` the grammar needs (a C-style
// `for` header, between the members of a one-line type body) stays.

class Point { var x: i32; var y: i32; };

fn f(x: i32) -> i32 {
    var a = 1; var b = 2;
    f(x);
    for var i: i32 = 0; i < 3; ++i { a += i; }
    if a > b { return a; }
    return b;
}
