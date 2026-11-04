// Corpus for main.k: a vector<usize> field and its uses.
ffi "c++" import "vector";

pub class Sizes {
    pub var e: cxx::std::vector<usize>;
    fn add(self, n: usize) { self.e.push_back(n); }
    fn at(self, i: usize, n: usize) -> usize { return self.e[i] + n; }
}

fn main() -> i32 { return 0; }
