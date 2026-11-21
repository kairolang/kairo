// top.k: the entry, which reaches both headers of the cycle.
import self::a::*
import self::b::*

pub fn top(k: i32) -> i32 {
    var a = apple_of(k, k)
    var b = banana_of(k, k)
    return a.grow() + b.peel()
}
