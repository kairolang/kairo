ffi "c++" import "takes.hh"

pub fn lib_takes(const s: cxx::std::string) -> i32 { return takes_str(s) }
