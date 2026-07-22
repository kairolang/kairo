// CASE 8: shadowing, not ambiguity. main defines its OWN `id`, and also
// imports bar's `id`. Both exist: the local decl in the TU's frozen table, the
// import in the overlay. NO error from phase I (local-vs-import is shadowing;
// unqualified lookup consults the overlay LAST, so the local wins). Ambiguity
// is strictly overlay-vs-overlay. Expect: overlay key `id` present (1 fn-set
// target from bar); local `id` in the TU symbol table; no diagnostic.

import bar::{id}

fn id(x: i32) -> i32 {
    return x + 1
}

fn use_shadowing() -> i32 {
    return id(3)
}
