// RUN: %kfmt --stdout %s | diff -u %S/Expected/calls.k -
// RUN: %kfmt --check %S/Expected/calls.k
//
// Rule 4.1 for calls: one line only when the call ends by column 80, else
// the block form, one argument per line with a trailing comma (4.2); an
// inner call that is still too long splits the same way. Named arguments
// align their values when broken (11.3). A written trailing comma on one
// line goes.

fn f() {
    report(
        DiagID::R049E,
        name_range,
        f"unknown name '{name}\x27 in this scope, and more",
    )

    short(a, b)
    outer(
        first_argument_value,
        inner_call(another_long_argument, yet_another_argument_value),
    )

    make(
        width:            1,
        height_in_pixels: 2,
        depth:            some_long_value_expression(),
        name:             "a box",
    )
}
