// Corpus for Parser/Serialize/macros.k: expands lib.k's macros and its own.
import lib::*
import std::io::println

macro third!(t) { t.2 }
macro sum3!(a, b, c) { wrap!(a) + wrap!(b) + c }

fn main() -> i32 {
    var t = (10, 20, 30)
    println(two!())
    println(greet!())
    return second!(t) + third!(t) + sum3!(1, 2, forty!()) - 93
}
