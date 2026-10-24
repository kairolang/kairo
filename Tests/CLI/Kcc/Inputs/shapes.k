import std::io::println

pub struct Point {
    pub var x: i32 = 0;
    pub var y: i32 = 0;
}

pub fn manhattan(p: Point) -> i32 {
    return p.x + p.y;
}

pub class Tracer {
    pub var hits: i32 = 0;

    pub fn Tracer(self) { println("Tracer()"); }
    @move pub fn Tracer(self, other: Self) = default;
    pub fn op delete(self) { println("~Tracer()"); }

    pub fn hit(self, n: i32) -> i32 {
        self.hits += n;
        return self.hits;
    }
}
