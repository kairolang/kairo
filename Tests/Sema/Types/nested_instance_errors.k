// A type nested in a generic class named through an instance (GH#91): the
// instance's argument list is checked like any other (it used to be
// dropped unread), and the member type must exist. These stop the TU
// before bodies are typed; the conversions are
// Tests/Sema/ExprTyper/nested_instance_mismatch.k.

class <K> L {
    pub struct P {
        pub var k: K
    }
    pub fn L(self) { }
    pub fn make(self, k: K) -> Self::P { return Self::P { k: k } }
}

fn main() -> i32 {
    var l = L<i32>()
    var c: L<i32, i64>::P = l.make(3)       // too many arguments
    var d: L<i32>::Q = l.make(4)            // no such member type
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:12: error [R032E]: 'L' takes at most 1 generic argument(s), but 2 were given
// DIAG-NEXT: {{.*}}:7:1: note [R032N]: declared here
// DIAG: {{.*}}:18:20: error [R025E]: no type named 'Q' in 'L'
// END-GENERATED-CHECKS(DIAG)
