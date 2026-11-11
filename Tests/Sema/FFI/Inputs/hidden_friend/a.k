ffi "c++" import "box.h"

pub fn same_a() -> bool {
    var x = Box<usize>()
    var y = Box<usize>()
    return x == y
}
