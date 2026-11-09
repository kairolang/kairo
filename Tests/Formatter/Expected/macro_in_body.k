// RUN: %kfmt --normalize-parens --stdout %s | diff -u %S/Expected/macro_in_body.k -
// RUN: %kfmt --normalize-parens --check %S/Expected/macro_in_body.k
//
// A declaration holding a macro use (`defined!` in an `eval if`, or
// any `name!(...)`) was copied as written whole, the enclosing class
// included. Only the macro use is copied; every other statement and every
// sibling member is laid out (8.1, 13.1, 9.5).

fn f(p: *i32) {
    eval if defined!(DEBUG) {
        g()
    }

    if *p == 0 {
        *p = 2
    }
}

fn h(p: *i32) {
    var x = foo!(1)
    if *p == 0 {
        *p = 2
    }

    eval for x in foo {
        g()
    }
}

class C {
    var count: usize

    fn check(self) {
        eval if defined!(DEBUG) {
            g()
        }
    }

    pub fn size(const self) -> usize {
        return self.count
    }
}

// exposed once these bodies were laid out: a `pub` declaration in a
// file-scope `eval if` kept its `pub`; a chained string's next literal
// keeps its `f` prefix
eval if defined!(__APPLE__) {
    pub eval CACHE_LINE: usize = 128
} else {
    pub eval CACHE_LINE: usize = 64
}

fn w(wide: string, i: i32) {
    eval if defined!(X) {
        g()
    }

    wide += f" a {i} b\n"
    " c\n"
    f"inline {i}(\n" + "}\n"
}
