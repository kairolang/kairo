// RUN: %kfmt --stdout %s | diff -u %S/expected/const_addr.k -
// RUN: %kfmt --check %S/expected/const_addr.k
//
// `const &x` keeps its one space between `const` and `&`, and none after
// the `&`; so does `unsafe const &x`.

fn f(a: i32, b: *i32) -> i32 {
    var p = const &a
    var u = unsafe const &a
    var t = (const &a, &b)
    return read(const &a) + read(p: const &*b)
}
