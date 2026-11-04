// Corpus for main.k: names an instance over a thing.h type without using it.
ffi "c++" import "memory"
ffi "c++" import "thing.h"

pub fn hold(p: unsafe *cxx::std::unique_ptr<xr::Thing>) -> unsafe *cxx::std::unique_ptr<xr::Thing> { return p }
