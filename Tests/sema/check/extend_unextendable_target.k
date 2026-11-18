// An extend cannot target a function type
// (SC283E) or a bare type parameter (SC284E), bounded or not, nor `T?`
// over one. One error per block, at the target, and nothing from the
// bodies, which use `self` and `Self`. A nullable POINTER is a pointer
// (SC282E). An operator in an extension of a nullable is not callable
// yet, so it is refused at its declaration (placeholder SC001E).
// A function-type target is an error too, not an internal one in CXXSpell.
interface I { fn m(self) -> i32 }

extend fn(i32) -> i32 { pub fn g(self) -> i32 { return self(1) } }
extend unsafe fn() { pub fn h(self) -> Self { return self } }
extend <T> T { pub fn k(self) -> Self { return self } }
extend <T impl I> T { pub fn k2(self) -> i32 { return self.m() } }
extend <T> T? { pub fn k3(self) -> Self { return self } }
extend *i32? { pub fn k4(self) -> i32 { return 1 } }
extend i32? { pub fn op +(self, o: i32) -> i32 { return o } }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: extend_unextendable_target.k:10:8: error [SC283E]: a function type cannot be extended; write a free function that takes the function as a parameter, or wrap it in a struct or class and extend that
// CHECK: extend_unextendable_target.k:11:15: error [SC283E]: a function type cannot be extended
// CHECK: extend_unextendable_target.k:12:12: error [SC284E]: ambiguous extend: 'T' is a bare type parameter, so this would add members to every type; extend a named type or a generic type such as '[T]' or 'Box<T>', or write a free generic function
// CHECK: extend_unextendable_target.k:13:19: error [SC284E]: ambiguous extend: 'T' is a bare type parameter, so this would add members to every type
// CHECK: extend_unextendable_target.k:14:12: error [SC284E]: ambiguous extend: 'T?' is a nullable of a bare type parameter, so this would add members to every nullable type
// CHECK: extend_unextendable_target.k:15:8: error [SC282E]: a pointer type cannot be extended
// CHECK: extend_unextendable_target.k:16:19: error [SC001E]: an extension of a nullable type cannot declare an operator yet; write a method, or extend the non-nullable type
