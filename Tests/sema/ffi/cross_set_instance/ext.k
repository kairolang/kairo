// Corpus for main.k: a record holding an instance from <set>.
ffi "c++" import "set"

pub class Ext {
    pub var s: cxx::std::set<string> = cxx::std::set<string>()
}
