import self::ext_lib::*

pub fn use_a() -> i32 {
    var m = Meter()
    return m.plain<i32>(6) + m.n
}
