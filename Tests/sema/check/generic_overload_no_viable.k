// A call to an overloaded free function from a generic body is checked
// against the candidates with the argument's declared type: when none
// accepts a value of that type the call is SC063E, with each candidate
// listed, and it is not left for the C++ compiler to pick per instance.

class Ex { pub var k: i32 = 0 }
class St { pub var k: i32 = 1 }

pub fn is_rec(p: unsafe *Ex) -> bool { return p->k == 7 }
pub fn is_rec(p: unsafe *St) -> bool { return p->k == 7 }

fn <T> check(x: T) -> bool { return is_rec(x) }

fn main() -> i32 {
    var e = Ex()
    var ok = unsafe check(&e)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: generic_overload_no_viable.k:12:37: error [SC063E]: no matching overload for call to 'is_rec'
// CHECK-NEXT: generic_overload_no_viable.k:9:5: note [I900N]: candidate not viable: cannot convert argument of type 'T' to parameter 'p' of type 'unsafe *Ex'
// CHECK-NEXT: generic_overload_no_viable.k:10:5: note [I900N]: candidate not viable: cannot convert argument of type 'T' to parameter 'p' of type 'unsafe *St'
