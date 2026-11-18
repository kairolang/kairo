// Imported by user.k: a generic class with a destructor and no transfer
// constructor over a C++ container of its parameter, whose category each
// instance decides.

ffi "c++" import "vector"

pub class <T> Bag {
    pub var items: cxx::std::vector<T>
    pub fn Bag(self) { }
    pub fn op finally(self) { }
}
