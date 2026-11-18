import self::ovl_lib::*

pub fn use_b() -> i32 {
    var s = Shape()
    var q = Sound()
    var n = kind_of<Probe>(&s)
    if is_a<Other>(&q) {
        n += 100
    }

    var raw: unsafe *const Sound = unsafe (&q as unsafe *const Sound)
    if is_a<Other>(raw) {
        n += 1000
    }

    return n
}
