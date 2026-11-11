ffi "c++" import "my_code.hh"

pub fn <T impl Addable> first(a: T, b: T) -> T { return a }

pub fn seven() -> i32 { return first(7, 8) }
