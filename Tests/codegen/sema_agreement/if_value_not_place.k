// An `if` expression of lvalues binds an imported C++ reference as the
// lvalue the emitted conditional is (if_lvalue_arms.k). To Kairo it is
// still a value and no place: an `@inout` parameter does not borrow it,
// it is not assigned to, and neither it nor a field of it has an address.

class Kc {
    pub var id: i32 = 0
    fn Kc(self, id: i32) {
        self.id = id
    }
}

fn bump(@inout x: i32) {
    x += 1
}

fn main() -> i32 {
    var c      = true
    var i: i32 = 1
    var j: i32 = 2
    var a      = Kc(1)
    var b      = Kc(2)
    bump(if (c) => (i) else => j)
    (if (c) => (i) else => j)    = 5
    (if (c) => (a) else => b).id = 9
    var q = unsafe &(if (c) => (i) else => j)
    return i
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: if_value_not_place.k:23:5: error [SC063E]: no matching overload for call to 'bump'
// CHECK: if_value_not_place.k:24:6: error [SC071E]: left side of assignment is not assignable
// CHECK: if_value_not_place.k:25:6: error [SC071E]: left side of assignment is not assignable
// CHECK: if_value_not_place.k:26:{{[0-9]+}}: error [SC069E]: cannot take the address of a temporary
