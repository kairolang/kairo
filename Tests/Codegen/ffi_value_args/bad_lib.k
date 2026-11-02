// Imported by two_tu_errors.k; not a test of its own (lit.local.cfg).
ffi "c++" import "vargs.h"

pub fn lib_bad() -> i32 {
    var w: Narrow<300>
    var f: Flag<3>
    return w.width() + f.get()
}
