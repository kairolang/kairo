// statics.k -- exit 4
struct Point { var x: i32; var y: i32; }
struct Vec2  { var x: i32; var y: i32; }

extend Point {
    static fn zero() -> Point { return Point { x: 0, y: 0 }; }
    static fn one() -> i32 { return 1; }
}
extend Vec2 {
    static fn zero() -> Vec2 { return Vec2 { x: 1, y: 1 }; }
    static fn one() -> i32 { return 2; }
}

fn main() -> i32 {
    var p = Point::zero();
    var v = Vec2::zero();
    return p.x + v.x + Point::one() + Vec2::one();
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// Two targets, two scopes: same member names, no collision.
// CXX: struct __kairo_ext_Point {
// CXX: struct __kairo_ext_Vec2 {
// CXX: int main() {
// CXX: ::statics::__kairo_ext_Point::one()
// CXX-SAME: ::statics::__kairo_ext_Vec2::one()

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 4
