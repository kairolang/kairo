// Corpus for main.k: ahead of it, a set that imports <vector> but not item.h,
// so `vector` is this set's.
ffi "c++" import "vector"

pub fn first_len(v: cxx::std::vector<i32>) -> usize { return v.size() }
