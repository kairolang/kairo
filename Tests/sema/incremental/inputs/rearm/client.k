import gen::*
import num::*

pub fn first() -> i32 {
    var t = Tagged<i32>{v: 1}
    return t.len()
}
