// aliased: handle rebound to `b`; qualified generic chain via the alias.
// Comment directly above the import regression-tests the S052E fix.
import bar as b

fn use_aliased() -> i32 {
    var e = b::id<i32>(3)
    var f = b::Box<i32>(4)
    return e + f.value
}
