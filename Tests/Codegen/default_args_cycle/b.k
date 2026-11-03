// Corpus for main.k: imports a, which imports it back.
import a::*
pub fn b_def(y: i32 = 3) -> i32 { return y }
pub fn b_use() -> i32 { return a_def() }
