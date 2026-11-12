import gen::*
import iface::*
import num::*
import rec::*

pub fn maybe(flag: bool) -> Point? {
    if flag {
        return origin()
    }

    return null
}

pub fn boxed() -> i32 {
    var b = Box<Point>{v: origin(2)}
    var ps: [Point] = [origin(), origin(1)]
    var n: i32 = 7
    return b.get().x + len_of(n) + ps[0].y
}
