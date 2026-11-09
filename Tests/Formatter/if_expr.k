// RUN: %kfmt --stdout %s | diff -u %S/Expected/if_expr.k -
// RUN: %kfmt --check %S/Expected/if_expr.k
//
// Rule 8.3: an `if` expression stays on one line while it fits;
// otherwise one clause per line at the `if`'s column, the keywords
// right-aligned so the conditions line up (`     if` / `else if` / `else`).
// With no `else if` there is no condition to line up: `else` goes under `if`.

fn f(x: i32) -> i32 {
    var s = if x > 0 => "positive" else => "non-positive";
    var t = if x > 1000000 => compute_large_value(x, another_argument) else if x > 0 => compute_small(x) else => fallback_value_for_negative(x);
    var u = if x > 1000000 => compute_large_value(x, another_argument) else => fallback_value_for_negative(x);
    return 0;
}
