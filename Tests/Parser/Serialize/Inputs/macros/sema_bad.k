// Corpus for Parser/Serialize/macros.k: Sema errors INSIDE expanded code,
// one from a macro of this file and one from lib.k's. Sema reports them
// against the tree's tokens, so a reloaded tree has to hold the same
// expansion records.
import lib::*

macro local_bad!() { no_such_name_here + 1 }

fn f() -> i32 {
    return local_bad!()
}

fn g() -> i32 {
    return bad!()
}
