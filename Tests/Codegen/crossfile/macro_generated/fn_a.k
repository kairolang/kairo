import self::fn_lib::*

pub fn use_a() -> i32 {
    var w: i64 = second<i64>(20)
    return first<i32>(1) + (w as i32) + third<u8>(0, 3) as i32
}
