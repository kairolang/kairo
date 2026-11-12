// Moving a std::optional / std::tuple / std::variant /
// std::expected of a move-only Kairo class compiles and runs (it was
// CL001E: the copy clang deletes was emitted). A std::span of one stays a
// view: copying it copies no element.

ffi "c++" import "expected"
ffi "c++" import "optional"
ffi "c++" import "span"
ffi "c++" import "tuple"
ffi "c++" import "variant"
ffi "c++" import "vector"

class Mv {
    pub var id: i32 = 0
    fn Mv(self) { self.id = 3 }
    fn Mv(self, id: i32) { self.id = id }
    @move fn Mv(self, other: Self) { self.id = other.id; other.id = 0 }
}

fn take_opt(o: cxx::std::optional<Mv>) -> i32 {
    return o.value().id
}

fn take_tup(t: cxx::std::tuple<Mv, i32>) -> i32 {
    return 2
}

fn take_var(v: cxx::std::variant<Mv, i32>) -> i32 {
    return v.index() as i32 // 0: holds the Mv
}

fn take_exp(e: cxx::std::expected<Mv, i32>) -> i32 {
    return e.value().id
}

fn span_len(s: cxx::std::span<Mv>) -> i32 {
    return s.size() as i32
}

fn main() -> i32 {
    var o = cxx::std::optional<Mv>(Mv(4))
    var o2 = o
    var t: cxx::std::tuple<Mv, i32>
    var t2 = t
    var va: cxx::std::variant<Mv, i32>
    var vb = va
    var ea: cxx::std::expected<Mv, i32>
    var eb = ea
    var v = cxx::std::vector<Mv>()
    v.push_back(Mv(1))
    var s = cxx::std::span<Mv>(v.data(), v.size())
    var s2 = s
    return take_opt(o2) + take_tup(t2) + take_var(vb) + take_exp(eb) + span_len(s) + span_len(s2) // 4 + 2 + 0 + 3 + 1 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 11
