// XFAIL: *
// Waits on the planned 0.3 design: `x.finally()`
// and `x.op finally()` are an explicit early destructor call, in place, with
// reuse afterwards; before 0.3 both are a "not implemented yet" error (SC116E).
// These are the assertions of the design as first built (§77), kept as written.
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
    r.acquire(5)
    r.op finally()
    r.acquire(6)
    println("end of main")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// `x.finally()` is C++'s explicit destructor call.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: r.~Res()

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
