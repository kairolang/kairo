import lib::*

fn recv() -> i32 {
    var h = Holder()
    var a = h.take_a()
    return h.a.n
}

fn inout() -> i32 {
    var h = Holder()
    var b = drain(&h)
    return h.b.n
}
