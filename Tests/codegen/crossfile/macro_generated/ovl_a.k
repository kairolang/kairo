import self::ovl_lib::*

pub fn use_a() -> i32 {
    var s = Shape()
    var n = 0
    if is_a<Probe>(&s) {
        n += 1
    }

    var q = Sound()
    return n + kind_of<Other>(&q)
}
