// RUN: %kfmt --stdout %s | diff -u %S/Expected/named_init.k -
// RUN: %kfmt --check %S/Expected/named_init.k
//
// Rule 4.10: a named initializer keeps one space inside its braces on one
// line; broken, one field per line in the block form, the values in one
// column (11.3), with a trailing comma (4.2).

fn f() {
    var c = Cmd { ind: 0, brk: true }
    var d = Cmd {
        indent: 0,
        brk:    true,
        doc:    some_long_document_expression(with_an_argument),
        lit:    "",
    }
}
