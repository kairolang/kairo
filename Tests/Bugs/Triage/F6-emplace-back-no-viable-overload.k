// build: kairo F6-emplace-back-no-viable-overload.k   (expect exit 3)
ffi "c++" import "vector"

class Cp {
    pub var n: i32 = 0
    fn Cp(self, n: i32) { self.n = n }
}

fn main() -> i32 {
    var v: cxx::std::vector<Cp>
    var k = Cp(1)
    v.emplace_back(k)       // COPY lvalue: copied, k stays live
    v.emplace_back(Cp(2))   // prvalue
    return v.size() as i32 + k.n
}
