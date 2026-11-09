// The entry of Tests/CLI/Driver/incremental_*.k: uses Box (its layout),
// ident (a generic body it instantiates) and calc (a signature and, with
// -finfer-purity, an inferred attribute); never `unused`.
import util::*

fn main() -> i32 {
    var b = Box()
    return b.get() + ident<i32>(2) + calc(1)
}
