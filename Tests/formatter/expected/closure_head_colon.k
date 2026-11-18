// RUN: %kfmt --stdout %s | diff -u %S/expected/closure_head_colon.k -
// RUN: %kfmt --check %S/expected/closure_head_colon.k
//
// Rule 6.1 in the parts of a head that are otherwise copied: the `:` of a
// generic parameter (`fn <eval N: usize>`) and of a closure's parameter
// (`fn (u: i32)`) is glued to the name with one space after it, whatever
// was written, as in a function's parameter list.

fn <eval N: usize> size() -> usize = N

fn <T, eval M: usize> pick(x: T) -> T {
    var g = fn (u: i32, v: i32) -> i32 { return u + v }
    var h = fn (u: i32) -> i32 = u * 2
    var k = fn <eval K: i32> () -> i32 { return K }
    var e = fn () -> i32 { return 1 }
    return x
}
