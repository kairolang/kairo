// CASE 1/11 (plain): `import bar` binds the module handle; bar::foo is
// qualified. Also case 11: bare `<` after a qualified segment disambiguates
// as generic via the chain-step path. Expect: overlay key `bar` -> 1 module
// target (src fid = bar), and the AST shows generic call/type nodes.

import bar

fn use_plain() -> i32 {
    var c = bar::id<i32>(3)
    var d = bar::Box<i32>(4)
    return c + d.value
}
