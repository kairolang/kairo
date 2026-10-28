// shape.k
pub class Shape {
    virtual fn area(const self) -> f64
    virtual fn sides(const self) -> i32 { return 0 }
}

pub class Square derives Shape {
    pub var side: f64
    pub fn Square(self, side: f64) { self.side = side }
    override fn area(const self) -> f64 = self.side * self.side
    override fn sides(const self) -> i32 = 4
}

// Kairo calling through the base: dispatches into whichever side defined it.
pub fn describe(s: *const Shape) -> f64 {
    return s->area() + s->sides()
}
