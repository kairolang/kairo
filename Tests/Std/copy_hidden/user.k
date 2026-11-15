import std
import self::geo::shapes::Pt

pub fn run() -> i32 {
    var p = Pt(1)
    var q = std::copy(p)
    return q.x
}
