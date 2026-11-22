// A local of an `async` function keeps its plain storage: the move checker
// walks no exit at an `await`, so a frame destroyed while suspended there
// could hold a local it takes to be moved. Its moved-from object is
// destroyed at the end of its scope, as C++ does it. The same body in a
// plain function has the local in union storage, with no destructor run
// for it.
import std::io::println

class Res {
    var id: i32 = 0
    fn Res(self, id: i32) { self.id = id }
    @move fn Res(self, other: Self) {
        self.id  = other.id
        other.id = 0
    }
    fn op finally(self) { println(f"~Res {self.id}") }
}

fn job() async -> i32 {
    var a = Res(1)
    var b = a
    return b.id
}

fn plain() -> i32 {
    var a = Res(2)
    var b = a
    return b.id
}

fn main() -> i32 {
    return plain() - 2
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: signed int job() noexcept {
// CXX-NEXT: ::{{.*}}::Res a = ::{{.*}}::Res(1);
// CXX-LABEL: signed int plain() noexcept {
// CXX-NEXT: ::__kairo_ul< ::{{.*}}::Res> __k_s_a {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      ~Res 2
// OUT-EMPTY:
