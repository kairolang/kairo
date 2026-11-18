// Constructors run in declaration order and destructors in reverse, on
// Windows as elsewhere.

import std::io::println

class Named {
    var name: string = ""
    fn Named(self, n: string) { self.name = n; println(f"ctor {n}") }
    fn op finally(self) { println(f"dtor {self.name}") }
}

fn main() -> i32 {
    var a = Named("A")
    var b = Named("B")
    println("body")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: ctor A
// CHECK-NEXT: ctor B
// CHECK-NEXT: body
// CHECK-NEXT: dtor B
// CHECK-NEXT: dtor A
