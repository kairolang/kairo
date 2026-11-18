ffi "c++" import "vector";

// A module `Dg` whose file `Dg.k` declares a class `Dg`: C++ namespace
// Dg::Dg holds class Dg, so `Dg::Dg` read inside it is the constructor.
pub class Dg {
    pub var n: i32 = 1
    pub var kids: cxx::std::vector<unsafe *Dg>
    pub fn get(self) -> i32 { return self.n }
}
