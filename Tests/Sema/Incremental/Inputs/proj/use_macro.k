import macros::*

pub fn use_macro() -> i32 {
    var v = 1
    return plus_one!(v)
}
