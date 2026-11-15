// `x.finally()` and `x.op finally()` run a local's destructor early, in
// place. A whole assignment afterwards constructs the local again, and the
// scope's end destroys what is then there.
import std::io::println

class Res {
    var id: i32 = 0
    var held: bool = false
    fn Res(self) = default
    fn Res(self, id: i32) { self.id = id; self.held = true }
    @move fn Res(self, other: Self) { self.id = other.id; self.held = other.held; other.held = false }
    fn acquire(self, id: i32) { self.id = id; self.held = true }
    fn op finally(self) {
        if self.held {
            println(f"release {self.id}")
            self.held = false
        }
    }
}

fn main() -> i32 {
    var r = Res(4)
    r.finally()
    println("after early")
    r = Res(5)
    r.op finally()
    r = Res(6)
    println("end of main")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// `x.finally()` ends the local's union storage.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: __k_s_r.__end();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      release 4
// CHECK-NEXT: after early
// CHECK-NEXT: release 5
// CHECK-NEXT: end of main
// CHECK-NEXT: release 6
// CHECK-EMPTY:
