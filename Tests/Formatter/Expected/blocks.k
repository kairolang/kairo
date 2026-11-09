// RUN: %kfmt --stdout %s | diff -u %S/Expected/blocks.k -
// RUN: %kfmt --check %S/Expected/blocks.k
//
// Rules 8.1 / 8.2 / 8.4 / 14.1 / 14.2 / 14.4: every block breaks, even one
// holding a single simple statement; `} else {` joins; block arms of
// a `match` chain onto the `}` before them; a blank line follows a
// `}` line; no blank line at a block's start or end; at most 4 blank
// lines kept; conditions are laid out from the tree.

fn f() {
    if x == 0 {
        out.push_back(sep)
    }

    if a {
        f()
    } else {
        g()
    }

    if k == 1 {
        ++a
    } else if k == 2 {
        ++b
    }

    match item.get_kind() {
        case TopLevelKind::Decl {
            self.dispatch_decl(item.as_decl())
        } case TopLevelKind::Stmt {
            self.dispatch_stmt(item.as_stmt())
        }
    }




    while n != 10 {
        n += 1
    }
}
