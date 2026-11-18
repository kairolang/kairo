// Corpus for main.k: imports b, which imports it back.
import b::*
pub fn a_val() -> i32 { return b_def() + 1 }
pub fn a_def(x: i32 = 2) -> i32 { return x }
