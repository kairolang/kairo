// Corpus for main.k: an input ahead of it whose header set imports
// <utility> but not err.h, so `std::move` is this set's.
ffi "c++" import "utility"

pub fn first_move(x: i32) -> i32 { var y = x; return cxx::std::move(y) }
