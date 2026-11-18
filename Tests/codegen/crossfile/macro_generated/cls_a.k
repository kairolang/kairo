import self::cls_lib::*

pub fn use_a() -> i32 {
    var b = Box<i32>(3)
    return b.get() + b.pick<i32>(10)
}
