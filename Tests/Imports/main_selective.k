// selective + item alias: `Boxx<i32>` must map back to bar's generic `Box`.
// Comment directly above the import regression-tests the S052E fix.
import bar::{id, Box as Boxx}

fn use_selective() -> i32 {
    var a = id<i32>(1)
    var c = Boxx<i32>(3)
    return a + c.value
}
