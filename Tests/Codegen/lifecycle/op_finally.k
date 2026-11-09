// The destructor is `fn op finally(self)` (classes-lifecycle.mdx, 0.2.0). It
// runs when the object's lifetime ends: at the end of its scope (in reverse
// declaration order), at `@destroy`, and as a member of an object being
// destroyed. (`x.finally()`, an early explicit call, is not implemented before
// 0.3; the early-call cases are Tests/Codegen/lifecycle/op_finally_early.k,
// XFAIL until the 0.3 design lands.)
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

class Pair {
    var a: Res
    var b: Res
    fn Pair(self) { self.a = Res(10); self.b = Res(11) }
    @move fn Pair(self, other: Self) = default
    fn op finally(self) { println("pair") }
}

fn scoped() {
    var x = Res(1)
    var y = Res(2)
    println("scope body")
}

fn main() -> i32 {
    scoped()
    println("after scope")

    var *h = @create Res(3)
    @destroy h
    println("after destroy")

    var *p = @create Pair()
    @destroy p
    println("after pair")

    var r = Res(4)
    r.acquire(5)
    println("end of main")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: ~Res()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      scope body
// CHECK-NEXT: release 2
// CHECK-NEXT: release 1
// CHECK-NEXT: after scope
// CHECK-NEXT: release 3
// CHECK-NEXT: after destroy
// CHECK-NEXT: pair
// CHECK-NEXT: release 11
// CHECK-NEXT: release 10
// CHECK-NEXT: after pair
// CHECK-NEXT: end of main
// CHECK-NEXT: release 5
// CHECK-EMPTY:
