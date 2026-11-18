// The entry; b imports it back.
import b::*

pub fn fa(n: i32) -> i32 {
    if n <= 0 { return 0 }
    return fb(n - 1) + 1
}

fn main() -> i32 {
    return fa(5) + fc()          // 5 + 40
}
