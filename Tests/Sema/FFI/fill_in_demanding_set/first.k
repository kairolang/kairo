// Corpus for main.k: an input ahead of it whose header set imports
// <vector> but not cell.h, so <vector>'s decls are this set's.
ffi "c++" import "vector"

pub fn first_len(v: cxx::std::vector<i32>) -> usize { return v.size() }
