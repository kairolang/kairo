// Corpus for main.k: the same uses, vector<u64> named first.
ffi "c++" import "vector";

fn main() -> i32 {
    var w = cxx::std::vector<u64>();
    var v = cxx::std::vector<usize>();
    const n: usize = 1;
    const x: u64 = 2;
    v.push_back(n);
    w.push_back(x);
    const i: usize = 0;
    const r: usize = v[i] + n;
    const s: u64 = w[i] + x;
    return 0;
}
