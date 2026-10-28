// A type nested in a generic class, named through an instance, is THAT
// instance's (GH#91): `L<i32>::P` and `L<f64>::P` are two types, and a
// member read through one has its argument's type (`b.k` is an i32, so the
// error names i32, not `K`). Both used to be the pattern's P.

class <K> L {
    pub struct P {
        pub var k: K
    }
    pub fn L(self) { }
    pub fn make(self, k: K) -> Self::P { return Self::P { k: k } }
}

fn main() -> i32 {
    var l = L<i32>()
    var a: L<f64>::P = l.make(1)
    var b: L<i32>::P = l.make(2)
    var s: string = b.k
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:16:24: error [SC028E]: cannot convert 'L<i32>::P' to 'L<f64>::P'
// DIAG: {{.*}}:18:21: error [SC028E]: cannot convert 'i32' to 'string'
// END-GENERATED-CHECKS(DIAG)
