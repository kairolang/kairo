// The SFINAE'd templates reached from another module: a plain wrapper,
// and a GENERIC one whose call is dependent here and is decided per
// instance, where the argument is concrete.

ffi "c++" import "../sfinae.h"

pub fn pick_int(x: i32) -> i32 { return on_default(x) }

pub fn <T> pick(x: T) -> i32 { return on_default(x) + on_return(x) }
