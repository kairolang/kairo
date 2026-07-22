// CASE 1 (selective + item alias) / 11: `import bar::{id, Box as Boxx}` brings
// both names UNQUALIFIED; `Box` aliased to `Boxx`. Expect: overlay keys `id`
// (fn-set) and `Boxx` (type, resolved from source `Box`). Bare generic uses
// disambiguate via the import edge.

import bar::{id, Box as Boxx}

fn use_selective() -> i32 {
    var a = id<i32>(1)
    var c = Boxx<i32>(3)
    return a + c.value
}
