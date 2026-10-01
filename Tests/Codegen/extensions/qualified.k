// qualified.k -- exit 3
struct Foo { var v: i32; }

extend Foo {
    fn add(self, x: i32) -> i32 { self.v += x; return self.v; }
    static fn zero() -> Foo { return Foo { v: 0 }; }
}

fn main() -> i32 {
    var a = Foo::zero();
    var r: i32 = 0;
    if a.v == 0             { r += 1; }
    if Foo::add(a, 4) == 4  { r += 1; }
    if a.v == 4             { r += 1; }
    return r;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// `Foo::add(a, 4)` takes `self` positionally, by address; a static member
// through the type is the callee alone.
// CXX: int main() {
// CXX: ::qualified::__kairo_ext_Foo::zero();
// CXX: __kairo_ext_Foo::add((& a), 4)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 3
