// CASE 2: selective import of a name that does NOT exist in the source module.
// `nonexistent` is not declared in bar. Expect: R015 "not declared in the
// imported module" emitted HERE (phase I, sole home). `id` still folds fine.

import bar::{id, nonexistent}

fn use_miss() -> i32 {
    return id<i32>(7)
}
