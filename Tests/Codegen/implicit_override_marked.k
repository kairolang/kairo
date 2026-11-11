// A derived method with the base virtual's parameters overrides it without
// being written `override` (classes-inheritance.mdx). The C++ spells
// `override` on it all the same: otherwise a class with one member marked
// `override` (here Rect's destructor, which the base's virtual one makes
// an override) and one not made clang warn "'area' overrides a member
// function but is not marked 'override'" (C505W), which the user cannot act
// on. Two levels: Square's `area` overrides through Rect's
// unmarked one.

class Shape {
    virtual fn area(const self) -> i64 { return 0 }
    virtual fn op finally(self) { }
}

class Rect derives Shape {
    var w: i64
    var h: i64
    fn Rect(self, w: i64, h: i64) { self.w = w; self.h = h }
    fn area(const self) -> i64 { return self.w * self.h }
}

class Square derives Rect {
    fn Square(self, s: i64) { Rect::Rect(self, s, s) }
    fn area(const self) -> i64 { return self.w * self.w + 1 }
}

fn main() -> i32 {
    var s: *Shape = @create<Rect>(2, 3)
    var q: *Shape = @create<Square>(2)
    var a = s->area() + q->area()
    @destroy(s)
    @destroy(q)
    return a as i32   // 6 + 5
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: C505W
// DIAG-NOT: error
// RUN: %t.exe; test $? -eq 11
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: area() const noexcept override
// IR: area() const noexcept override
