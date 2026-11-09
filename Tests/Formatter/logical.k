// RUN: %kfmt --stdout %s | diff -u %S/Expected/logical.k -
// RUN: %kfmt --check %S/Expected/logical.k
//
// Rule 4.6: a chain of `&&` (or `||`) that does not fit breaks BEFORE every
// operator, each continuation one level in.

fn f() {
    if is_constructor(f) && f->params.size() == 1 && is_self_type(f->params[0]) && (!f->is_deleted) {
        g();
    }
    var ok = a || b;
}
