import self::fn_lib::*

pub fn use_b() -> i32 {
    var w: i64 = first<i64>(200)
    return second<i32>(2) + (w as i32) + third<i32>(0, 4)
}
