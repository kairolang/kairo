// The entry; b imports it back. Each file uses a macro the other defines.
import b::*

pub fn base_a() -> i32 { return 20 }
pub fn plus_a(p: i32, q: i32) -> i32 { return p + q }
pub macro from_a!(x) { plus_a(base_a(), x) }

fn main() -> i32 {
    var v = 1
    return from_b!(v) + b_uses_a()      // (10 + 1) + (20 + 2)
}
