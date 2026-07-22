// plain: names reached qualified; `<` after a segment via chain-step path.
// Comment directly above the import regression-tests the S052E fix.
import bar

fn use_plain() -> i32 {
    var c = bar::id<i32>(3)
    var d = bar::Box<i32>(4)
    return c + d.value
}
