// Corpus for main.k: checked ahead of it with a different header set, it
// fills the nested iterator instance (so that instance is imported from ITS
// AST) without ever looking through its base.
ffi "c++" import "iter.h"
ffi "c++" import "other.h"

pub fn first_walk(o: unsafe *xr::Owner) -> bool {
    var it = o->specs().begin()
    var n = it.own()
    return true
}
