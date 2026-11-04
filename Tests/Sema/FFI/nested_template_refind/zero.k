// Corpus for main.k: a third header set that imports the iterator header
// first, so the templates' primary decls belong to a set neither first.k nor
// main.k uses.
ffi "c++" import "iter.h"

pub fn zero_walk(o: unsafe *xr::Owner) -> bool { return true }
