import shapes::*
import hub::*
pub fn viahub(p: Point) -> i32 {
    var q = p + p
    return p.twice() + p.half() + q.x + quad(p)
}
