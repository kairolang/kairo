ffi "c" import "hdr.h"
import util
import shapes

fn main() -> i32 {
    var p = shapes::Point{x: 1, y: 2}
    var z = 5 as i32
    return util::triple(shapes::sum(p)) + hdr_k() - 2 + z - 5
}
