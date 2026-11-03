// Corpus for Preprocessor/fstring_macro_holes.k (the input).
import lib::*
import std::io::println

macro g!(x) { f"v={x}" }
macro m! { 42 }
macro h!(a, b) { a + b }
macro both!(x) { f"{x}:{m!}:{h!(x, 1)}" }

fn main() -> i32 {
    var n = 7
    println(g!(1))
    println(g!(n + 1))
    println(f"v={m!}")
    println(f"v={h!(1, 2)}")
    println(both!(n))
    println(show!(5))
    println(shown!)
    return 0
}
