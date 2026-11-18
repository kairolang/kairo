ffi "c++" import "h1.h"
ffi "c++" import "h3.h"

fn main() -> i32 {
    var b: Base
    var c: n::Base
    b.a = 2
    c.c = 3
    return f1() + b.a + (c.c as i32) - 6
}
