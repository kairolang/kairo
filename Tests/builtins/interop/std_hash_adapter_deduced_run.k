// `into_cxx()` of a HashSet / HashMap over a Kairo key, kept in a deduced
// local, used as a temporary, held in a generic record's field and as a
// C++ container's element: the C++ container's type is the conditional
// extension member's return type instantiated at the key, the default
// hasher included, so the file specializes `std::hash<K>` for it as for a
// written type.

ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"
ffi "c++" import "vector"

class Tok impl Hash {
    pub var id: i64

    pub fn Tok(self, id: i64) {
        self.id = id
    }

    @move pub fn Tok(self, other: Self) {
        self.id  = other.id
        other.id = -1
    }

    pub fn op == (const self, const o: Tok) -> bool {
        return self.id == o.id
    }

    fn hash(const self, @inout h: Hasher) {
        h.write_usize(self.id as usize)
    }
}

class <T impl Hash> Holder {
    pub var s: cxx::std::unordered_set<T>
}

fn mk() -> {Tok} {
    var s = HashSet<Tok>()
    s.insert(Tok(5))
    return s
}

fn main() -> i32 {
    var h = Holder<Tok>{s: mk().into_cxx()}
    var n = mk().into_cxx().size()
    var w = cxx::std::vector<cxx::std::unordered_set<Tok>>()
    w.push_back(mk().into_cxx())
    var s = HashSet<Tok>()
    s.insert(Tok(3))
    s.insert(Tok(4))
    var x = s.into_cxx()
    var m = HashMap<string, i32>()
    m.insert("a", 1)
    var y = m.into_cxx()
    return (x.size() * 10 + y.size() + h.s.size() + n + w.size()) as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 24
