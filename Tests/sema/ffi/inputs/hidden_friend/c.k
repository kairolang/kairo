ffi "c++" import "box.h"
import b::*

pub fn same_c() -> bool {
    var x = Box<usize>()
    var y = Box<usize>()
    return (x == y) && same_b()
}
