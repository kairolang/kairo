// An f-string hole in a `<T: type>` body is formatted per instance: a value
// of type T, and a member result reached through T (the CRTP mixin's
// `self.dyn()->tu.str(...)`, whose type only the instance knows). The body
// is emitted once, as a C++ template, and the put is picked at each
// instance from the value's C++ type (LowerTargets::fmt_dyn). Neither is
// SC080E "an interpolation in a generic body needs a concrete type".

import std::io::println

class TU {
    fn str(self, x: i32) -> string { return f"t{x}" }
    fn num(self) -> i64 { return 40 }
}

class <X: type> Mixin {
    priv inline fn dyn(self) -> unsafe *X { return unsafe ((unsafe &self) as unsafe *X) }
    fn line(self) -> string { return f"is '{self.dyn()->tu.str(2)}' and {self.dyn()->tu.num()}" }
}

class Seven derives Mixin<Seven> {
    pub var tu: TU
}

class Named {
    fn Named(self) { }
    pub fn repr(const self) -> string = "named"
}

fn <T: type> twice(x: T) -> string { return f"{x}+{x}" }

fn main() -> i32 {
    var s = Seven()
    println(s.line())
    println(twice(3))
    println(twice(true))
    println(twice("ab"))
    println(twice(Named()))
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo -fduck-generics %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo -fduck-generics %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK: is 't2' and 40
// CHECK-NEXT: 3+3
// CHECK-NEXT: true+true
// CHECK-NEXT: ab+ab
// CHECK-NEXT: named+named
