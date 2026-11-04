import item::*
ffi "c++" import "<vector>"

// A C++ template instance whose argument is a Kairo class from a third
// file: main's C++ holds Store complete, so `std::vector<Item *>` is
// written there and must find Item declared.
pub class Store {
    pub var items: cxx::std::vector<unsafe *Item>
    pub fn Store(self) {}
    pub fn count(self) -> usize { return self.items.size() }
}
