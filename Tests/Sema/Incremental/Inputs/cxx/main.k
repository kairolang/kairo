ffi "c++" import "vector"
import local::*

struct Own {
    var n: i32
}

fn main() -> i32 {
    var v = cxx::std::vector<Local>()
    v.push_back(Local{a: first()})
    var w = cxx::std::vector<Own>()
    w.push_back(Own{n: 2})
    var i: usize = 0
    return v[i].a + w[i].n
}
