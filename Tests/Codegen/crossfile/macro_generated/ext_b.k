import self::ext_lib::*

pub fn use_b() -> i32 {
    var m = Meter()
    return m.copied<i32>(9) + m.n
}
