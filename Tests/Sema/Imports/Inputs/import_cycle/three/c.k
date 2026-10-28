// Closes the cycle a -> b -> c -> a.
import a::*

pub fn fc() -> i32 { return 1 }
pub fn back() -> i32 { return fa() }
