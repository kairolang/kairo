ffi "c" import "hdr.h"
import geo
import use_counter::*
import use_gen::*
import use_hidden::*
import use_util::*

fn main() -> i32 {
    var p = geo::Point{x: 1, y: 2}
    return geo::sum(p) + use_gen() + use_util() + use_hidden() + hdr_k()
}
