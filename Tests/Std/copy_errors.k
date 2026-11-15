// std::copy of a type that has neither a copy constructor nor a `copy()`
// method is an error naming the type and both ways to make it copyable.

import std

class Neither {
    pub var n: i32
    pub fn Neither(self, n: i32) {
        self.n = n
    }

    @move pub fn Neither(self, other: Self) {
        self.n = other.n
    }
}

fn main() -> i32 {
    var x = Neither(1)
    var y = std::copy(x)
    return y.n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: copy_errors.k:19:13: error [SC063E]: no matching overload for call to 'copy'
// CHECK-NEXT: utility.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: its 'requires' clause does not hold: 'Neither' does not implement 'CopiesItself': it has no 'copy'
// CHECK-NEXT: utility.k:{{[0-9]+}}:{{[0-9]+}}: note [I900N]: candidate not viable: its 'requires' clause does not hold: 'Neither' does not implement 'Copy': it cannot be copied by a copy constructor
// CHECK-NOT: error
