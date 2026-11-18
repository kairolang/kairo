import self::cls_lib::*

pub fn use_b() -> i32 {
    var c = Cell<i32>(5)
    return c.get() + c.pick<i32>(20)
}
