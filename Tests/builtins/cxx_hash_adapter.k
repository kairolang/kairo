// A Kairo record that conforms to the two-word Hash as the key of an
// imported C++ hash container: `std::hash<Key>` is specialized over the
// Hash witness, which feeds a Hasher the adapter makes. Compiled and
// linked; nothing is hashed, since Hasher has no body yet.

ffi "c++" import "unordered_map";

class Key impl Hash {
    pub var a: i32 = 0;
    pub var b: i32 = 0;
    fn Key(self, a: i32, b: i32) { self.a = a; self.b = b; }
    fn hash(const self, @inout h: Hasher) { h.write_usize((self.a * 31 + self.b) as usize) }
    fn op ==(const self, const other: Key) -> bool { return (self.a == other.a) && (self.b == other.b); }
}

class Table {
    pub var keys: cxx::std::unordered_map<Key, i32>;
    fn Table(self) {
        self.keys = cxx::std::unordered_map<Key, i32>();
    }
}

fn main() -> i32 {
    var t = Table();
    return 0
}

// --- lit wiring ---
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s --print-ir 2>&1 | %FileCheck %s
// CHECK: ::builtin::base::hash::Hasher h(0);
// CHECK: return static_cast<decltype(sizeof(0))>(h.finish());
