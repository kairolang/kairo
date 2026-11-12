// A binary operator an `extend T?` block declares, T a record with
// no such operator of its own: `a + b` on two `Money?` calls it with the
// nullables as they are, so it runs for null and non-null operands alike,
// with no `if a?` first. It was refused at the declaration (SC001E) when
// operator typing could only read a nullable operand as its value. Each
// check returns its own number.

struct Money { var c: i32 }

extend Money? {
    fn op + (self, o: Money?) -> Money? {
        if self == null || o == null { return null }
        return Money{ c: self.c + o.c }
    }

    // null sorts first
    fn op < (self, o: Money?) -> bool {
        if self == null { return o != null }
        if o == null { return false }
        return self.c < o.c
    }
}

fn main() -> i32 {
    var a: Money? = Money{ c: 3 }
    var b: Money? = Money{ c: 4 }
    var n: Money? = null

    var s? = a + b
    if s == null { return 1 }
    var t? = a + n
    if t != null { return 2 }
    var u? = n + n
    if u != null { return 3 }

    if !(n < a) { return 4 }
    if a < n { return 5 }
    if !(a < b) { return 6 }
    if n < n { return 7 }

    var v = s ?? Money{ c: 0 }
    if v.c != 7 { return 8 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TC --allow-empty
// TC-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
