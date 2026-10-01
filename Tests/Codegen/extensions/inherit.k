// inherit.k -- exit 32
class Shape  { pub var side: i32; }
class Square derives Shape { pub var tag: i32; }

extend Shape {
    fn area(const self) -> i32 { return self.side * self.side; }
    fn grow(self, by: i32) { self.side += by; }
}

fn main() -> i32 {
    var q = Square();
    q.side = 3;
    q.grow(1);
    var p: *Square = &q;
    return p->area() + q.area();
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// A member found through a base takes the BASE's receiver: the derived
// object's address is cast up, keeping its cv.
// CXX: int main() {
// CXX: static_cast< ::inherit::Shape *>((& q))
// CXX: static_cast<const::inherit::Shape *>(p)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 32
