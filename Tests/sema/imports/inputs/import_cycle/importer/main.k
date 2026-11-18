// Not on the cycle: imports into it from outside.
import a::*
import b::*

fn main() -> i32 { return fa() + fd() }   // 42 + 42
