// Corpus for Preprocessor/fstring_chain_macro_holes.k (the input).
import lib::*
import std::io::println

macro g!(x) { "v=" f"{x}" }
macro m! { 42 }
macro both!(x) { "<" f"{x}" ":" f"{m!}" ">" }

fn main() -> i32 {
    var n = 7
    println(g!(1))
    println(g!(n + 1))
    println("v=" f"{m!}")
    println(both!(n))
    println(show!(5))
    println(shown!)
    return 0
}
