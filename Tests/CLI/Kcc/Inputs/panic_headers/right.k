// right.k: returns Panic<i32, Shared>, as left.k does.
import errs::*
pub fn right(k: i32) panic(Shared) -> i32 {
    if k < 0 { panic Shared { code: 2 } }
    return k + 2
}
