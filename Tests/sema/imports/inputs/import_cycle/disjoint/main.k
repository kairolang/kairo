// Two cycles that share no file: a <-> b and c <-> d.
import a::*
import c::*

fn main() -> i32 { return fa() + fc() }   // 3 + 30
