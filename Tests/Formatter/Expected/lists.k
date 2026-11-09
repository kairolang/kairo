// RUN: %kfmt --stdout %s | diff -u %S/Expected/lists.k -
// RUN: %kfmt --check %S/Expected/lists.k
//
// Rule 4.1 for list and tuple literals: one line when they fit, else the
// block form with a trailing comma (4.2), or the grid for more than six
// short items.

fn f() {
    var xs = [1, 2, 3]
    var names = [
        "alpha", "beta",  "gamma", "delta", "epsilon", "zeta", "eta", "theta",
        "iota",  "kappa",
    ]

    var long_values = [
        compute_first_value(argument),
        compute_second_value(argument),
        third_one(argument),
    ]

    var pair = (a, b)
}
