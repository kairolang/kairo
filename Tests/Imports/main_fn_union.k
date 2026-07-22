// CASE 4: same function name imported from two modules -> ONE overlay key with
// TWO fn-set targets that UNION into one overload set. NO error (function sets
// merge; only non-function targets clash). Expect: overlay key `id` with 2
// targets, both fn-set, no R016.

import bar::{id}
import baz::{id}

fn use_union() -> i32 {
    return id<i32>(9)
}
