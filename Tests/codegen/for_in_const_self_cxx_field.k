// `for x in self.v` in a `const self` method iterates a const
// vector; the range holder must keep the const.
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe

ffi "c++" import "vector";
class P {
    pub var segs: cxx::std::vector<i32>;
    fn total(const self) -> i32 {
        var t: i32 = 0;
        for s in self.segs { t += s; }
        return t;
    }
}
fn main() -> i32 {
    var p = P { segs: cxx::std::vector<i32>() };
    p.segs.push_back(2); p.segs.push_back(3);
    if p.total() == 5 { return 0; }
    return 1;
}
