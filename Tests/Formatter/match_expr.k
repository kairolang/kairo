// RUN: %kfmt --stdout %s | diff -u %S/Expected/match_expr.k -
// RUN: %kfmt --check %S/Expected/match_expr.k
//
// Rule 8.4 (decided 2026-11-08): a `match` expression with more than
// 2 cases always breaks: `match a {`, one `case` per line one level in,
// `}`. With 2 cases or fewer it is copied as written.

fn f(a: i32) -> i32 {
    var x = match a { case 1 => 10 case 2 => 20 case 3 => 30 };
    var y = match a { case 1 => 10 default => 20 };
    return match a { case 1 => x
        case 2 => y default => 0 };
}
