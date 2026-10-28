// left.k: returns Panic<i32, Shared>, as right.k does.
import errs::*
pub fn left(k: i32) panic(Shared) -> i32 {
    if k < 0 { panic Shared { code: 1 } }
    return k + 1
}
