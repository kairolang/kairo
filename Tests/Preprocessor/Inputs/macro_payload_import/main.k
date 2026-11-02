// Corpus for Preprocessor/macro_payload_import.k: expands lib.k's macros.
import lib::*
import std::io::println

macro third!(t) { t.2 }

fn main() -> i32 {
    var t = (10, 20, 30)
    println(two!())
    println(greet!())
    return second!(t) + third!(t)
}
