// circle.k
import std::io::println
ffi "c++" import "shape.hh"

pub class Square derives Shape {
    pub var side: f64

    pub fn Square(self, side: f64) {
        self.side = side
    }

    override fn area(const self) -> f64 = self.side * self.side
    override fn sides(const self) -> i32 = 4
}

pub fn kairo_report() -> f64 {
    var s = Square(3.0)
    return report(s)                         // Kairo object into C++ by base reference
}