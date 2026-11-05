// O43: a Kairo record as the key of an imported C++ hash container. The
// registry spells `cxx::std::unordered_map<string, i32>` with its default
// hasher, `std::hash<builtin::string::string>`, whose primary libc++
// disables for a type C++ was never told about: "call to implicitly-deleted
// default constructor of 'std::hash<...>'" plus four __hash_table follow-ons,
// though string conforms to Hash. Each TU that names `std::hash<K>` for a
// Kairo K impl Hash now specializes it over the Hash witness -- for the
// builtin string (an extension conformance in another module) and for a
// user record (its own members).

ffi "c++" import "unordered_map";

class Key impl Hash {
    pub var a: i32 = 0;
    pub var b: i32 = 0;
    fn Key(self, a: i32, b: i32) { self.a = a; self.b = b; }
    fn hash(const self) -> usize { return (self.a * 31 + self.b) as usize; }
    fn op ==(const self, const other: Key) -> bool { return (self.a == other.a) && (self.b == other.b); }
}

class Table {
    pub var names: cxx::std::unordered_map<string, i32>;
    pub var keys: cxx::std::unordered_map<Key, i32>;
    fn Table(self) {
        self.names = cxx::std::unordered_map<string, i32>();
        self.keys = cxx::std::unordered_map<Key, i32>();
    }
}

fn main() -> i32 {
    var t = Table();
    t.names["one"] = 1;
    t.names["two"] = 2;
    t.keys[Key(1, 2)] = 10;
    t.keys[Key(2, 1)] = 20;
    var r: i32 = 0;
    if t.names.find("two") != t.names.end() { r += t.names["two"]; }
    if t.keys.find(Key(2, 1)) != t.keys.end() { r += t.keys[Key(2, 1)]; }
    if t.names.contains("three") { r += 100; }
    if t.keys.contains(Key(9, 9)) { r += 100; }
    return r + (t.names.size() as i32) + (t.keys.size() as i32);
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// RUN: %t.exe; test $? -eq 26
// RUN: { %kairo %s --print-ir -o %t2.exe 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<> struct hash< ::builtin::string::string> {
// CXX: template<> struct hash< ::cxx_unordered_map_kairo_key::Key> {
// CXX: class Table {
// CXX: inline decltype(sizeof(0)) hash< ::cxx_unordered_map_kairo_key::Key>::operator()(const::cxx_unordered_map_kairo_key::Key & v) const noexcept {
