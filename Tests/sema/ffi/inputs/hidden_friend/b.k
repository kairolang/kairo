ffi "c++" import "box.h"
import a::*

pub fn same_b() -> bool {
    var x = Box<u64>()
    var y = Box<u64>()
    return (x == y) && same_a()
}
