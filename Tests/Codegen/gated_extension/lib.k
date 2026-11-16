// A Kairo function with a C++ string parameter, for a caller that has no
// C++ header of its own.
ffi "c++" import "takes.hh"

pub fn lib_takes(const s: cxx::std::string) -> i32 { return takes_str(s) }
