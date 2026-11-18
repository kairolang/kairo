ffi "c" import "c_add.h"
ffi "c++" import "sub/deep.h"

pub inline fn lib_sum(a: i32, b: i32) -> i32 { return deep_twice(c_add(a, b)) }
pub inline fn lib_mac(a: f64, b: f64, c: f64) -> f64 { return c_mac(a, b, c) }
