// Keys of C++ hash containers that conform to Hash, by an `impl Hash` or
// structurally, written or reached through a generic function's return type, and a Kairo record without
// Hash held only by a container that names no hasher: none is an error.

ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"
ffi "c++" import "vector"

class Declared impl Hash {
    pub var a: i32 = 0
    fn Declared(self, a: i32) { self.a = a }
    fn hash(const self, @inout h: Hasher) { h.write_u64(self.a as u64) }
    fn op == (const self, const other: Declared) -> bool { return self.a == other.a }
}

class Structural {
    pub var a: i32 = 0
    fn Structural(self, a: i32) { self.a = a }
    pub fn hash(const self, @inout h: Hasher) { h.write_u64(self.a as u64) }
    pub fn op == (const self, const other: Structural) -> bool { return self.a == other.a }
}

class Plain {
    pub var a: i32 = 0
    fn Plain(self, a: i32) { self.a = a }
}

fn <T> make_set() -> cxx::std::unordered_set<T> {
    return cxx::std::unordered_set<T>()
}

fn main() -> i32 {
    var m = cxx::std::unordered_map<Declared, i32>()
    m[Declared(1)] = 2
    var s = make_set<Declared>()
    s.insert(Declared(3))
    var t = cxx::std::unordered_set<string>()
    t.insert("one")
    var u = cxx::std::unordered_set<Structural>()
    u.insert(Structural(5))
    var v = cxx::std::vector<Plain>()
    v.push_back(Plain(1))
    return (m.size() + s.size() + t.size() + u.size() + v.size()) as i32
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
// RUN: rm -f %t.exe && rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
