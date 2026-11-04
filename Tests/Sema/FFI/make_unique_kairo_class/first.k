// Corpus for main.k: ahead of it, a set that imports <memory> but not
// base.h, so `make_unique` is this set's and `mu::Base` is not.
ffi "c++" import "memory"

pub fn first_unique() -> cxx::std::unique_ptr<i32> { return cxx::std::make_unique<i32>(1) }
