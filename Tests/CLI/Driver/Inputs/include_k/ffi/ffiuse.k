ffi "c++" import "vec2.h"
ffi "c" import "cnum.h"

pub fn len2(v: Vec2) -> i32 {
    return v.x * v.x + v.y * v.y;
}

pub inline fn twice_c(x: i32) -> i32 {
    return c_twice(x);
}
