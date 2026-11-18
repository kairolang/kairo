// point.k
pub class Point {
    pub var x: i32
    pub var y: i32

    pub fn Point(self, x: i32, y: i32) {
        self.x = x
        self.y = y
    }

    pub fn op == (const self, other: Point) -> bool {
        return self.x == other.x && self.y == other.y
    }
}