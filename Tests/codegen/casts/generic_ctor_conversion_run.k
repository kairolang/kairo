// A cast or a construction through a target's generic constructor, on a
// value of a parameter whose bound grants the constructor's: `a as Box` and
// `Box(a)` run that constructor at each instance, and `a as string` on a
// `T impl ByteRange` copies a C++ string's bytes.

ffi "c++" import "string"

interface Shape {
    fn area(const self) -> i32
}

class Sq impl Shape {
    pub var s: i32 = 0
    pub fn area(const self) -> i32 = self.s * self.s
}

class Box {
    pub var n: i32 = 0
    pub fn Box(self) {}
    pub fn <S impl Shape> Box(self, const s: S) {
        self.n = s.area()
    }
}

fn <T impl Shape> cast_shape(a: T) -> Box = a as Box
fn <T impl Shape> ctor_shape(a: T) -> Box = Box(a)
fn <T impl ByteRange> text(a: T) -> string = a as string

fn main() -> i32 {
    var q = Sq{ s: 3 }
    if cast_shape(q).n != 9 { return 1 }
    if ctor_shape(q).n != 9 { return 2 }
    if text(cxx::std::string("kairo")) != "kairo" { return 3 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O0 -o %t.exe --cache-dir %t.d0
// RUN: %t.exe
