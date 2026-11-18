// A member's `requires` clause and the untaken branch of an `eval if` in its
// body are decided per instance: an instance whose argument fails the clause
// does not instantiate the member, and a branch its `sizeof` test rejects is
// not instantiated, so neither is compiled for a type it cannot accept.

interface Shape { fn area(const self) -> i32 }
fn <U> sized(x: U) -> i32 requires U impl Shape { return x.area() }
struct Four { pub var a: i32 }                       // 4 bytes, not a Shape
class Big impl Shape { pub var a: i64 = 9
    pub fn Big(self) { }
    pub fn area(const self) -> i32 = self.a as i32 }
class <T> Holder {
    pub var v: T
    pub fn Holder(self, v: T) { self.v = v }
    pub fn total(const self) -> i32 requires T impl Shape {
        return sized<T>(self.v)
    }
    pub fn bits(const self) -> u64 {
        eval if sizeof T == 8 {
            return __builtin_bitcast<u64, T>(self.v)
        } else {
            return 1
        }
    }
    pub fn both(const self) -> i32 requires T impl Shape {
        eval if sizeof T == 8 {
            return sized<T>(self.v)
        } else {
            return 0
        }
    }
}
fn main() -> i32 {
    var f = Holder<Four>(Four { a: 1 })          // total/both must not instantiate for Four
    var b = Holder<Big>(Big())
    var u8h = Holder<u8>(7)
    var d = Holder<f64>(1.0)
    var r = 0
    if f.bits() == 1 { r = r + 1 }               // 4-byte: else branch
    if u8h.bits() == 1 { r = r + 2 }
    if d.bits() == 0x3FF0000000000000 { r = r + 4 }
    r = r + b.total() + b.both()                  // 9 + 9
    return r                                      // 1+2+4+18 = 25
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 25
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe; test $? -eq 25
