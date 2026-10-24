// build: kairo F7-const-move-value-passed-by-value.k   (expect a Sema error at the call, not clang's CL001E)
ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn main() -> i32 {
    var v: cxx::std::vector<Mv>
    const cm = Mv(1)
    v.push_back(cm)         // binds push_back(const T&): a copy of a MOVE value
    return v.size() as i32
}
