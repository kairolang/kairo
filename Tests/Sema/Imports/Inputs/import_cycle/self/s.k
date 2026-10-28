// A file that imports itself.
import s::*

pub fn one() -> i32 { return 1 }
fn main() -> i32 { return one() + 6 }
