// `op in` is a Kairo type's one iteration protocol. This class also has
// begin()/end() -- the kind a class exported to C++ defines for its C++
// callers -- and `for` must still go through `op in`, never through them.
// C++'s begin/end protocol is for imported C++ classes only (cxx_range.k).

class Pair {
    var a: i32
    var b: i32

    pub fn Pair(self, a: i32, b: i32) { self.a = a; self.b = b }

    pub fn op in (self) -> yield i32 {
        yield self.a
        yield self.b
    }

    pub fn begin(self) -> i32 { return 100 }
    pub fn end(self) -> i32 { return 200 }
}

fn main() -> i32 {
    var s: i32 = 0
    for x in Pair(3, 4) { s += x }
    return s                            // 7: op in, not begin/end
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:     __kairo_iter()
// CXX-NOT: .begin()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
