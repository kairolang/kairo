import shapes

pub fn moved(p: shapes::Point, dx: i32) -> shapes::Point {
    var q = p;
    q.x += dx;
    return q;
}
