// RUN: %kfmt --stdout %s | diff -u %S/Expected/param_colon.k -
// RUN: %kfmt --check %S/Expected/param_colon.k
//
// Rule 6.1: in a parameter, `name: Type`, the `:` glued to the name and one
// space after it, whatever was written. Fields, locals and named arguments
// already read that way. A closure's head is copied as written (1.7).

fn w(xs : [const i32;], y :i32, @inout z   :   i32, d : i32 = 3) -> i32 {
    var l = fn (u : i32) -> i32 { return u }
    return f(x : 1)
}

fn wide(first_parameter_name : i32, second_parameter : u64, third : [const i32;]) -> i32 {
    return 0
}
