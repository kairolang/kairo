// A union's constructors and operator overloads are checked like a struct's:
// every pass that walks the tree reaches their bodies.

union Bits {
    var word:  i32
    var ratio: f32

    fn Bits(self, seed: i32) {
        var bad: i32 = "not an int"
        self.word = missing_in_ctor + bad
    }

    fn op +(self, other: Bits) -> i32 {
        return missing_in_operator
    }
}

fn main() -> i32 {
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-DAG: union_member_bodies.k:9:24: error [SC028E]: cannot convert 'string' to 'i32'
// CHECK-DAG: union_member_bodies.k:10:21: error [R020E]: use of undeclared identifier 'missing_in_ctor'
// CHECK-DAG: union_member_bodies.k:14:16: error [R020E]: use of undeclared identifier 'missing_in_operator'
