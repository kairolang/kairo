import shapes::*
pub fn user(p: Point) -> i32 {
    var q = p + p
    return p.twice() + p.half() + q.x
}
