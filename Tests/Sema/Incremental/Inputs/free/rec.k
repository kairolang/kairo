pub struct Point {
    pub var x: i32
    pub var y: i32
}

pub fn origin(shift: i32 = 0) -> Point {
    return Point{x: shift, y: shift}
}
