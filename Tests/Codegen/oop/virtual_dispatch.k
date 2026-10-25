// Virtual dispatch through a base pointer (classes-inheritance.md, Virtual
// Dispatch): an override replaces the slot, a virtual nobody overrides
// keeps the base's body, an override two levels down wins, a `final
// override` is still an override, and a NON-virtual base method calling a
// virtual dispatches on the dynamic type (template method). A virtual
// destructor runs derived-first, each base after.
//
// Every call goes through a `*Shape`. Calling an overridden method on the
// derived type itself (`sq.area()`) is ambiguous today -- see
// override_direct_call.k -- and is kept out of this file on purpose. The
// default constructors exist only because a derived constructor cannot
// call a base one yet (base_ctor_call.k), so clang default-builds bases.

var drops: i32 = 0      // one digit per destructor, oldest first

class Shape {
    virtual fn area(const self) -> i32 { return -1 }
    virtual fn sides(const self) -> i32 { return 0 }
    fn describe(const self) -> i32 { return self.area() * 100 + self.sides() }
    virtual fn op delete(self) { drops = drops * 10 + 1 }
    fn Shape(self) { }
    @copy fn Shape(self, const other: Self) = delete
}

class Square derives Shape {
    prot var s: i32
    fn Square(self) { self.s = 0 }          // Tagged's base: no base-ctor call yet
    fn Square(self, s: i32) { self.s = s }
    override fn area(const self) -> i32 { return self.s * self.s }
    override fn sides(const self) -> i32 { return 4 }
    override fn op delete(self) { drops = drops * 10 + 2 }
}

class Tagged derives Square {
    fn Tagged(self, s: i32) { self.s = s }
    final override fn sides(const self) -> i32 { return 5 }
}

class Circle derives Shape {
    var r: i32
    fn Circle(self, r: i32) { self.r = r }
    override fn area(const self) -> i32 { return 3 * self.r * self.r }
}

fn area_of(s: *const Shape) -> i32 { return s->area() }

fn main() -> i32 {
    var r = 0
    {
        var sq = Square(3)
        var ci = Circle(2)
        var tg = Tagged(2)
        var a: *Shape = &sq
        var b: *Shape = &ci
        var c: *Shape = &tg
        if (a->area() == 9) && (b->area() == 12) { r += 1 }
        if b->sides() == 0 { r += 2 }           // inherited, not overridden
        if (c->sides() == 5) && (area_of(c) == 4) { r += 4 }   // two levels down
        if a->describe() == 904 { r += 8 }      // non-virtual caller, virtual callees
        if c->describe() == 405 { r += 16 }
    }
    // Reverse declaration order: tg runs Square's then Shape's (2, 1), ci
    // only Shape's (1), sq Square's then Shape's (2, 1).
    if drops == 21121 { r += 32 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
