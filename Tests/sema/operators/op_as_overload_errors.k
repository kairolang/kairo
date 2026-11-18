// `op as` overloads are told apart by target, so the errors are about
// targets: a cast to a target none of them returns is SC027E (no second
// conversion rides on a user one), and two `@implicit` conversions that
// each meet a parameter of an overloaded function leave the call
// ambiguous, since a user conversion ranks the same whatever its target.
// An exact target is fine. Two conversions to ONE target are in
// op_as_same_target.k (R041E stops the pass before these are typed).

class Two {
    var c: i32
    fn Two(self, c: i32) { self.c = c }
    @implicit fn op as(const self) -> i32 { return self.c }
    @implicit fn op as(const self) -> i64 { return 9 }
}

fn take(x: i32) -> i32 { return x }
fn take(x: i64) -> i32 { return 1 }

fn main() -> i32 {
    var t = Two(3)
    var s = t as f64
    var k = take(t)
    var ok = t as i64                   // ok: an exact target
    return 0
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:21:13: error [SC027E]: no conversion from 'Two' to 'f64'
// DIAG: {{.*}}:22:13: error [SC064E]: call to 'take' is ambiguous: more than one candidate matches at the same rank
// DIAG-NEXT: {{.*}}:16:1: note [I900N]: candidate declared here
// DIAG-NEXT: {{.*}}:17:1: note [I900N]: candidate declared here
// DIAG-NEXT: {{.*}}:22:13: note [I900N]: conversions are not ordered within a rank; cast one argument to make the choice explicit
// END-GENERATED-CHECKS(DIAG)
