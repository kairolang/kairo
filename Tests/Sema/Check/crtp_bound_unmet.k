// A CRTP base's bounds are Kairo's to check, at the class that names the
// instance, with that class complete -- never left to clang (whose concept
// on the template head used to fire at the base-specifier, before the
// class had any members; crtp_bounded.k). A deriving class that does not
// meet the `impl` bound, or names the base over another class, is an
// error here.

interface Valued {
    fn value(const self) -> i32
}

class <X derives Doubler<X> impl Valued> Doubler {
    fn doubled(const self) -> i32 { return (&self as *const X)->value() * 2 }
}

// Derives the instance named after itself but has no `value`.
class Bad derives Doubler<Bad> {
    fn other(const self) -> i32 { return 1 }
}

// Names the instance over a class that is not a Doubler.
class Plain {
    fn value(const self) -> i32 { return 3 }
}
class Wrong derives Doubler<Plain> {
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:17:19: error [SC001E]: 'Bad' does not conform to 'Valued': no member 'value' with the requirement's signature
// DIAG-NEXT: {{.*}}:12:8: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:9:5: note [I900N]: 'value' is required here
// DIAG: {{.*}}:25:21: error [SC001E]: 'Plain' does not derive 'Doubler<Plain>'
// DIAG-NEXT: {{.*}}:12:8: note [I900N]: required by this bound
// END-GENERATED-CHECKS(DIAG)
