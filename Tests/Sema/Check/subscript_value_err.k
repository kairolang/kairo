struct A {
    var x: i32
    pub fn op -> (self) -> i32 { return self.x }                        // expect: error arrow-must-return-pointer
}
struct B {
    var x: i32
    pub fn op [] (self, i: usize) -> unsafe *i32 { return unsafe &self.x }   // expect: error place-unsafe-pointer
    pub fn op .* (self, i: usize) { }                                   // expect: error no-result
    pub fn op ->* (self, i: usize) -> i32 { return self.x }             // a value operator, accepted
}
fn main() -> i32 {
    var a: [i32;] = [1, 2]
    var p = &a[0..1]                                                    // expect: error address-of-rvalue
    a[0..1] = a                                                         // expect: error assign-to-rvalue
    var q = &a[0]                                                       // the place form, fine
    return 0
}
// expect: no other diagnostics

// --- lit wiring -----------------------------------------------------------
// The value form of `op []` (the builtin slice's range overload here) is an
// rvalue with no special case: taking its address and assigning to it are
// the ordinary errors.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     subscript_value_err.k:3:{{[0-9]+}}: error [SC113E]: 'op ->' must return a pointer
// DIAG:     subscript_value_err.k:7:{{[0-9]+}}: error [SC114E]: 'op []' cannot return 'unsafe *T'
// DIAG:     subscript_value_err.k:8:{{[0-9]+}}: error [SC055E]: 'op .*' must return a value or a place
// DIAG:     subscript_value_err.k:13:{{[0-9]+}}: error [SC069E]: cannot take the address of a temporary
// DIAG:     subscript_value_err.k:14:{{[0-9]+}}: error [SC071E]: left side of assignment is not assignable
// DIAG-NOT: {{error|warning}} [
