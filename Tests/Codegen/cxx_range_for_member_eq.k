// A range-for over a C++ vector inside a class that declares its own `op ==`
// emitted the iterator test as `operator ==(it, end)`; the member found by name
// lookup hid the std one from ADL. A free imported operator is now written infix.

ffi "c++" import "vector";
enum K derives u32 { A, B }
class T {
    pub var kind: K = K::A;
    fn op == (const self, other: T) -> bool { return self.kind == other.kind; }
    fn op == (self, kinds: cxx::std::vector<K>) -> bool {
        for kind in kinds {
            if self.kind == kind {
                return true;
            }
        }
        return false;
    }
    fn op != (self, kinds: cxx::std::vector<K>) -> bool { return !(self == kinds); }
}
fn main() -> i32 { var t = T(); var v = cxx::std::vector<K>(); v.push_back(K::A); if t == v { return 3 } return 0 }

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: CL001E
// RUN: %t.exe; test $? -eq 3
