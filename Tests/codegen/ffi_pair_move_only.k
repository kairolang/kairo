// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 8
// A std::pair of a move-only Kairo class moves: into a variable, into a
// by-value parameter and out of a function.

ffi "c++" import "utility"

class Mv {
    pub var id: i32 = 0
    fn Mv(self) { self.id = 3 }
    @move fn Mv(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn take(p: cxx::std::pair<Mv, i32>) -> i32 {
    return p.first.id + p.second
}

fn make() -> cxx::std::pair<Mv, i32> {
    var o: cxx::std::pair<Mv, i32>
    o.second = 2
    return o
}

fn main() -> i32 {
    var o = make()
    var p = o
    return take(p) + 3 // 5 + 3
}
