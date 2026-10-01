// crossfile/point.k
pub struct Point { var x: i32; var y: i32; }

extend Point {
    pub fn sum(const self) -> i32 { return self.x + self.y; }
}
