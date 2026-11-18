// Imports the entry that imports it.
import a::*

pub fn fb(n: i32) -> i32 { return fa(n) }   // mutual recursion across the cycle
pub fn fc() -> i32 { return 40 }
