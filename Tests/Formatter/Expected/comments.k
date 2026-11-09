// RUN: %kfmt --stdout %s | diff -u %S/Expected/comments.k -
// RUN: %kfmt --check %S/Expected/comments.k
//
// Section 12: comment text is never changed; own-line comments are
// re-indented; a comment on an opener's line stays there; a block holding
// only comments stays a block; an expression holding a comment is copied
// as written.

class Foo { // why
    // re-indented
    var x: i32
}

fn f() {
    if x {
        // only a comment
    }

    var v = call(a, /* inline */ b)
    /* block
       comment */
}
