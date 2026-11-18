// Corpus for main.k: ahead of it, a set that imports <memory> but not
// item.h, so `make_shared` is this set's and `ms::Item` is not.
ffi "c++" import "memory"

pub fn first_shared() -> cxx::std::shared_ptr<i32> { return cxx::std::make_shared<i32>(1) }
