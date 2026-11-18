// The derived `op =`'s other forms (classes-lifecycle.mdx): a NON_TRANSFER
// class has none (SC071E on use), a moved-from MOVE value cannot be read
// (the assignment moved it, SC052E), and writing `op =` is an error
// (SC055E, SC058E): there is exactly one, generated.

class N {
    pub var v: i32 = 0
    fn N(self, v: i32) { self.v = v }
    @copy fn N(self, const other: Self) = delete
    @move fn N(self, other: Self) = delete
}

class M {
    pub var v: i32 = 0
    fn M(self, v: i32) { self.v = v }
    @move fn M(self, other: Self) { self.v = other.v }
}

class W {
    pub var v: i32 = 0
    @copy fn W(self, const other: Self) { self.v = other.v }
    fn op =(self, const other: Self) -> *Self { return &self }
}

fn main() -> i32 {
    var a = N(1)
    var b = N(2)
    a = b
    var c = M(1)
    var d = M(2)
    c = d
    var e = d
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: derived_assign_rules.k:22:5: error [SC055E]: '=' is not overloadable; assignment is generated from the type's constructors
// CHECK-DAG: derived_assign_rules.k:22:5: error [SC058E]: 'W' defines 'op ='; assignment is derived from the transfer constructor and cannot be written
// CHECK-DAG: derived_assign_rules.k:28:5: error [SC071E]: cannot assign a 'N': its transfer constructor is deleted
// CHECK-DAG: derived_assign_rules.k:32:13: error [SC052E]: 'd' is used after being moved
