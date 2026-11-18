// Corpus for main.k: the next set, the first to import item.h, so
// `cq::Item` is this set's and not main.k's.
ffi "c++" import "item.h"

pub fn second_x(i: cq::Item) -> i32 { return i.x }
