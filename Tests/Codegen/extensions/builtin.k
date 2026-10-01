// builtin.k -- exit 42
extend i32 {
    fn twice(const self) -> i32 { return self * 2; }
    fn bump(self) { self += 1; }
}

fn main() -> i32 {
    var x: i32 = 20;
    x.bump();
    return x.twice() + (21).twice() - 42;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// A builtin target: scope named by the Kairo spelling. `self` as a VALUE
// is `(*self)`, never the pointer, or `self * 2` is pointer arithmetic.
// CXX: struct __kairo_ext_i32 {
// CXX: __kairo_ext_i32::twice(const signed int * self) {
// CXX-NEXT: return((* self) * 2);
// CXX: ((* self) += 1);
// CXX: int main() {
// CXX: __kairo_ext_i32::bump((& x));
// CXX: __kairo_ext_i32::twice( ::__kairo_tmp(21))

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 42
