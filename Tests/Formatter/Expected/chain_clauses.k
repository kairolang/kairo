// RUN: %kfmt --stdout %s | diff -u %S/Expected/chain_clauses.k -
// RUN: %kfmt --check %S/Expected/chain_clauses.k
//
// Rules 8.2 / 8.4 / 8.11 (decided 2026-11-08): a clause chains onto
// the `}` before it: `} else if c {`, `} else {`, `} catch E {`,
// `} finally {` after a statement `try`, and `} case B {` / `} default {`
// for the block arms of a match statement. Value arms (`case A => 1`) are
// not blocks: one per line. A comment between two arms keeps them apart.

fn f(k: i32) {
    if k == 1 {
        a()
    } else if k == 2 {
        b()
    } else {
        c()
    }

    try {
        risky()
    } catch e: IoError {
        handle(e)
    } catch {
        other()
    } finally {
        cleanup()
    }

    match k {
        case 1 {
            one()
        } case 2 { // stays on the arm's first line
            two()
        } case 3 {
            three()
        }

        // the last arm
        default {
            other()
        }
    }

    match k {
        case 1 => one()
        case 2 => two()
        default => other()
    }
}
