pub struct Vec2 {
    pub var x: f64;
    pub var y: f64;
}

pub fn dot(a: Vec2, b: Vec2) -> f64 { return a.x * b.x + a.y * b.y; }

extend Vec2 {
    pub fn len(self) -> f64 { return 0.0; }
}

pub class <T> Box {
    pub var val: T;
    pub fn get(self) -> T { return self.val; }
}
