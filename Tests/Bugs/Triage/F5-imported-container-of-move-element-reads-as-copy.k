// build: kairo F5-imported-container-of-move-element-reads-as-copy.k   (expect exit 0: `var all = words` moves)
ffi "c++" import "vector"

class Mv {
    pub var n: i32 = 0
    fn Mv(self, n: i32) { self.n = n }
    @move fn Mv(self, other: Self) { self.n = other.n }
}

fn main() -> i32 {
    var words: cxx::std::vector<Mv>
    words.push_back(Mv(1))
    var all = words         // vector<Mv> should be MOVE; this is emitted as a copy
    return all.size() as i32
}
