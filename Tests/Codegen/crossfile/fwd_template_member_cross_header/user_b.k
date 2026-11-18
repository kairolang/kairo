ffi "c++" import "def.h"

pub fn make_and_read(x: i32) -> i32 {
    var w = fx::Wrap<i32>(x)
    w.set(w.get() + 1)
    var d = fx::Wrap<i32>()
    return w.get() + d.get()
}
