import left::*

pub fn drain_b(@inout h: Holder) -> Str { return h.b }

pub fn right_uses_left() -> i32 {
    var h = Holder()
    var a = h.take_a()
    return h.a.n
}
