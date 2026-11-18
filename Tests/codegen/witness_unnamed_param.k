// An interface requirement may leave a parameter unnamed
// (`fn op + (self, Self) -> Self`). The witness member C++ calls through
// forwards every parameter, so an unnamed one gets a name of its own; it
// used to be emitted with no name and the C++ did not parse. The witness
// is emitted whether or not anything conforms, so declaring the interface
// beside an unrelated class is enough to need it.

interface Add {
    fn op + (self, Self) -> Self
}

interface Sub {
    fn op - (self, Self) -> Self
}

interface Scale {
    fn scaled(self, i32, i32) -> i32
}

pub class Box {
    pub var v: i32
    pub fn Box(self, v: i32) { self.v = v }
    pub fn op + (self, const other: Self) -> Self { return Box(self.v + other.v) }
    pub fn op - (self, const other: Self) -> Self { return Box(self.v - other.v) }
    pub fn scaled(self, k: i32, by: i32) -> i32 { return self.v * k + by }
}

fn <T impl Add> sum(a: T, b: T) -> T { return a + b }
fn <T impl Sub> diff(a: T, b: T) -> T { return a - b }
fn <T impl Scale> scale(a: T) -> i32 { return a.scaled(2, 1) }

fn main() -> i32 {
    var s = sum(Box(4), Box(3))
    var d = diff(s, Box(2))
    // (4 + 3 - 2) * 2 + 1 = 11
    return scale(d)
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
