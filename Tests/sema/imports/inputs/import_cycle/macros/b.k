// Walked before a.k (it is what a.k imports), yet expands the macro a.k defines.
import a::*

pub fn base_b() -> i32 { return 10 }
pub fn plus_b(p: i32, q: i32) -> i32 { return p + q }
pub macro from_b!(x) { plus_b(base_b(), x) }

pub fn b_uses_a() -> i32 {
    var w = 2
    return from_a!(w)
}
