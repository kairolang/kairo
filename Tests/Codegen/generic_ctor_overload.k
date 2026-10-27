// Two constructors of a generic class, one taking a concrete type and one
// taking `T`: overload resolution sees the instance's constructors, where
// `T` is the argument, so `Opt<i32>(NullT {})` takes the first exactly and
// `Opt<i32>(5)` the second (functions-overloading.mdx: an exact match
// beats a conversion; an unviable candidate is dropped).
//
// The instance's arguments bind the pattern's parameters before any
// argument is ranked (MONO.md G4), so `v: T` is `v: i32` here and never
// deduces T := NullT from the call. A method the same way: `o.set(2)`
// takes the i32. The rejected forms are Tests/Sema/Types/
// instance_member_params.k.

struct NullT { }

class <T> Opt {
    pub var k: i32 = 0
    fn Opt(self, n: NullT) { self.k = 1 }
    fn Opt(self, v: T) { self.k = 2 }
    fn set(self, v: T) { self.k = 3 }
    fn set(self, n: NullT) { self.k = 4 }
}

fn main() -> i32 {
    var a = Opt<i32>(NullT { })
    var b = Opt<i32>(5)
    var c = Opt<i32>(5)
    c.set(2)
    var d = Opt<i32>(5)
    d.set(NullT { })
    return a.k * 1000 + b.k * 100 + c.k * 10 + d.k   // 1234 & 0xff = 210
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 210
