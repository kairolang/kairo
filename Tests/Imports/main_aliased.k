// CASE 1 (aliased): `import bar as b` rebinds the handle to `b`; original
// name `bar` is unavailable. Expect: overlay key `b` -> 1 module target.

import bar as b

fn use_aliased() -> i32 {
    var e = b::id<i32>(3)
    var f = b::Box<i32>(4)
    return e + f.value
}
