// Corpus for main.k: a record holding an instance from ITS header set.
ffi "c++" import "set"

pub class Ext {
    priv var _s: cxx::std::set<string> = cxx::std::set<string>()
}
