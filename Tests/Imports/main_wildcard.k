// CASE 1 (wildcard) / 3 (priv fact) / 11: `import bar::*` brings every top-level
// name UNQUALIFIED, non-pub included. Expect overlay keys: `id` (fn-set, pub),
// `Box` (type, pub), `limit` (type, pub), and `secret` (fn-set, PRIV  the fact
// N will later read to emit "exists but priv"). Bare `id<i32>`/`Box<i32>`
// disambiguate as generic; `limit < 3` stays a comparison (negative control).

import bar::*

fn use_wildcard() -> i32 {
    var a = id<i32>(1)
    var c = Box<i32>(3)
    var e = limit < 3
    return a + c.value
}
