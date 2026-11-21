// A Kairo record used as the key of a C++ hash container names
// `std::hash<K>` as the container's default hasher. That hasher is defined
// only by the specialization emitted over K's Hash conformance, so a key
// that does not conform to Hash is SC162E at the use: a member with
// another signature, a missing member, or a key reached through a generic
// function's return type. None of them reaches clang.

ffi "c++" import "unordered_map"
ffi "c++" import "unordered_set"

// `hash` with a signature other than the requirement's.
class OldSig impl Hash {
    pub var a: i32 = 0
    fn OldSig(self, a: i32) { self.a = a }
    fn hash(const self) -> usize { return (self.a * 31) as usize }
    fn op == (const self, const other: OldSig) -> bool { return self.a == other.a }
}

// No `hash` at all, and no `impl Hash`.
class NoHash {
    pub var a: i32 = 0
    fn NoHash(self, a: i32) { self.a = a }
    pub fn op == (const self, const other: NoHash) -> bool { return self.a == other.a }
}

// Reached only through a generic function's return type.
class Reached impl Hash {
    pub var a: i32 = 0
    fn Reached(self, a: i32) { self.a = a }
    fn hash(const self) -> u64 { return self.a as u64 }
    fn op == (const self, const other: Reached) -> bool { return self.a == other.a }
}

fn <T> make_set() -> cxx::std::unordered_set<T> {
    return cxx::std::unordered_set<T>()
}

fn main() -> i32 {
    var m = cxx::std::unordered_map<OldSig, i32>()
    m[OldSig(1)] = 2
    var s = cxx::std::unordered_set<NoHash>()
    s.insert(NoHash(1))
    var r = make_set<Reached>()
    r.insert(Reached(1))
    return (m.size() + s.size() + r.size()) as i32
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: cxx_hash_key_nonconforming.k:39:{{[0-9]+}}: error [SC162E]: 'OldSig' does not conform to 'Hash': no member 'hash' with the requirement's signature
// CHECK-DAG: cxx_hash_key_nonconforming.k:41:{{[0-9]+}}: error [SC162E]: 'NoHash' does not conform to 'Hash': no member 'hash' with the requirement's signature
// CHECK-DAG: cxx_hash_key_nonconforming.k:43:{{[0-9]+}}: error [SC162E]: 'Reached' does not conform to 'Hash': no member 'hash' with the requirement's signature
// CHECK-NOT: CL00{{[0-9]}}E
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=BUILD
// BUILD: error [SC162E]
// BUILD-NOT: CL00{{[0-9]}}E
// BUILD-NOT: std::hash
// RUN: test ! -e %t.exe
