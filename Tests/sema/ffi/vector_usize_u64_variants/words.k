// Corpus for main.k: a vector<u64> field and its uses.
ffi "c++" import "vector";

pub class Words {
    pub var w: cxx::std::vector<u64>;
    fn add(self, x: u64) { self.w.push_back(x); }
    fn at(self, i: usize, x: u64) -> u64 { return self.w[i] + x; }
}
