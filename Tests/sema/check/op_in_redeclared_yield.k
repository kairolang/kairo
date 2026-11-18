// Two `op in (self)` are one operator declared twice, whatever each
// yields: a type picks one yield form, value or pointer, for each
// receiver constness.

class Twice {
    var a: i32 = 0
    fn op in (self) -> yield i32 {
        yield self.a
    }

    fn op in (self) -> yield *i32 {
        yield &self.a
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: op_in_redeclared_yield.k:11:5: error [R041E]: class member 'op in' cannot be redeclared
// CHECK-NEXT: op_in_redeclared_yield.k:7:5: note [R041N]: previous declaration is here
