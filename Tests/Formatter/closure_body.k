// RUN: %kfmt --normalize-parens --stdout %s | diff -u %S/Expected/closure_body.k -
// RUN: %kfmt --normalize-parens --check %S/Expected/closure_body.k
//
// Rule 9.7: a closure's head is copied, its block body is laid out
// like any block (8.1, 13.1, 9.5). A body written on one line with one
// statement stays on one line. A comment or a macro use in the body is
// the body's: the call around the closure is still laid out.

fn f(p: *i32) {
    if !self.check(
        fn(k: TokenKind) -> bool {
            return Self::_is_expr_ident_kind(k);
        },
    ) {
        g();
    }

    run(fn(fid: u32) {
        var t = load(fid);
        if (*p) == 0 { (*p) = t; }
    })

    op_form(at, fn () { s->spell(at, p); }, fn () { self._value((*p)); }, t)

    suite.equal<string>("name", "pass", fn () -> string {
        var pair = fresh();
        // a comment in the body
        if (!pair.ok) && x { return "bad"; }
        return "pass";
    }, 1000)

    pool.enqueue(fn () |u, job| {
        eval if defined!(DEBUG) { trace(); }
        u->build(job);
    })

    var make = fn (content: string) -> i32 {
        // owned here
        var t = content;
        return (*p);
    }
}
