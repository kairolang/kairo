// A struct body admits fields, nested types, constructors and operator
// overloads. None of these is a named function, so none is rejected.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
struct Point {
    var x: i32
    var y: i32

    fn Point(self, x: i32, y: i32) { self.x = x; self.y = y }
    @copy
    fn Point(self, other: Self) { self.x = other.x; self.y = other.y }
    inline fn op == (self, other: Self) -> bool = (self.x == other.x) && (self.y == other.y)
    fn op != (self, other: Self) -> bool = !(self == other)

    struct Nested { var z: i32 }
    enum Tag { A, B }
}
