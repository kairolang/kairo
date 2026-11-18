pub struct Point {
    pub var x: i32
    pub var y: i32
}

pub fn sum(p: Point) -> i32 {
    return p.x + p.y
}

pub fn scale(p: Point, k: i32) -> i32 {
    var a = p.x * k
    var b = p.y * k
    return a + b
}
// SLOT
