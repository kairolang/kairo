// Names both operators of C inside a generic body: every file that
// instantiates `bump` reads this body.

import lib::C

pub fn <T> bump(c: C, t: T) -> i32 {
    var x = c
    x++
    ++x
    return x.v
}
