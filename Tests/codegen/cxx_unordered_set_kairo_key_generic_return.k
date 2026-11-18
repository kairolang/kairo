// A C++ hash container over a Kairo key whose type no expression of this
// file writes: a generic function returns `cxx::std::unordered_set<T>` and
// the caller keeps it in a deduced local, uses it as a temporary, holds it
// in a generic record's field and as a C++ container's element. Its type is the same instance
// the written `cxx::std::unordered_set<Key>` is, the default hasher
// `std::hash<Key>` included, so this file specializes `std::hash<Key>` over
// the Hash witness as it would for the written type.

ffi "c++" import "unordered_set"
ffi "c++" import "vector"

class Key impl Hash {
    pub var a: i32 = 0
    fn Key(self, a: i32) { self.a = a }
    fn hash(const self) -> usize { return (self.a * 31) as usize }
    fn op == (const self, const other: Key) -> bool { return self.a == other.a }
}

fn <T> make_set() -> cxx::std::unordered_set<T> {
    return cxx::std::unordered_set<T>()
}

class <T> Holder {
    pub var s: cxx::std::unordered_set<T>
}

fn main() -> i32 {
    var s = make_set<Key>()
    s.insert(Key(1))
    s.insert(Key(2))
    s.insert(Key(1))
    var t = make_set<string>()
    t.insert("one")
    var h = Holder<Key>{s: make_set<Key>()}
    h.s.insert(Key(4))
    var v = cxx::std::vector<cxx::std::unordered_set<Key>>()
    v.push_back(make_set<Key>())
    return (s.size() + t.size() + make_set<Key>().size() + h.s.size() + v.size()) as i32
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
