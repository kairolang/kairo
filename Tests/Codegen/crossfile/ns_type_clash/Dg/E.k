ffi "c++" import "vector";
import Dg::Dg::*;

pub class E {
    pub var d: Dg
    pub var all: cxx::std::vector<unsafe *Dg>
    pub fn run(self) -> i32 { return self.d.get() + 1 }
}
