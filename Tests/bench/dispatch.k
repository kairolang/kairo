// Virtual dispatch over a mixed array of 1024 shapes, N passes.
import std::io::println
ffi "c++" import "bench_env.h"

class Shape {
    fn Shape(self) { }
    @move fn Shape(self, other: Self) = default
    virtual fn area(const self) -> i64 { return 0 }
    virtual fn op delete(self) { }
}

class Rect derives Shape {
    var w: i64
    var h: i64
    fn Rect(self, w: i64, h: i64) { self.w = w; self.h = h }
    override fn area(const self) -> i64 { return self.w * self.h }
}

class Square derives Shape {
    var s: i64
    fn Square(self, s: i64) { self.s = s }
    override fn area(const self) -> i64 { return self.s * self.s }
}

class Tri derives Shape {
    var b: i64
    var h: i64
    fn Tri(self, b: i64, h: i64) { self.b = b; self.h = h }
    override fn area(const self) -> i64 { return self.b * self.h / 2 }
}

fn main() -> i32 {
    var passes: i64 = bench_n()
    var shapes: [*Shape?; 1024]
    for var i: usize = 0; i < 1024; i += 1 {
        var k = i as i64
        var m = (k * 7919) % 3
        if m == 0 { shapes[i] = @create<Rect>(k % 13 + 1, k % 7 + 1) }
        else if m == 1 { shapes[i] = @create<Square>(k % 11 + 1) }
        else { shapes[i] = @create<Tri>(k % 17 + 2, k % 5 + 2) }
    }
    var total: i64 = 0
    for var p: i64 = 0; p < passes; p += 1 {
        for var i: usize = 0; i < 1024; i += 1 {
            var s? = shapes[i]
            if s? { total += s->area() }
        }
    }
    for var i: usize = 0; i < 1024; i += 1 {
        var s? = shapes[i]
        if s? { @destroy(s) }
    }
    println(f"{total}")
    return 0
}
