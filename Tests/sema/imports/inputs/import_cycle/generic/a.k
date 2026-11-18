import b::*

pub fn <T> first(x: T, y: T) -> T { return x }
fn main() -> i32 { return pick(3, 4) + first<i32>(10, 20) }   // 4 + 10
