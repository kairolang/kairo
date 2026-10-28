// Conformance errors of generic associated types (interfaces.md,
// Associated Types):
//  - one named at an argument that does not meet its parameter's bound
//    (`T::Map<Plain>` of `type <K impl Show> Map`), as a generic record's
//    argument would not;
//  - a conformer whose alias has the wrong arity does not supply it, and
//    the error says so rather than "declares no associated type".

interface Show { fn show(const self) -> i32 }
interface Store {
    type <K impl Show> Map
}
struct Plain { pub var v: i32 }
class Bag impl Store {
    type <K> Map = K
    fn Bag(self) { }
}
class Flat impl Store {
    type Map = i32
    fn Flat(self) { }
}
fn <T impl Store> holds(s: T, m: T::Map<Plain>) -> i32 { return 0 }
fn <T impl Store> take(s: T) -> i32 { return 0 }

fn main() -> i32 {
    var d = take(Bag())
    var e = take(Flat())
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:22:34: error [SC001E]: 'Plain' does not conform to 'Show': no member 'show' with the requirement's signature
// DIAG-NEXT: {{.*}}:11:11: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:9:18: note [I900N]: 'show' is required here
// DIAG: {{.*}}:27:13: error [SC001E]: 'Flat' does not conform to 'Store': its 'Map' takes 0 generic parameter(s), and the associated type takes 1
// DIAG-NEXT: {{.*}}:23:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:19:5: note [I900N]: 'Flat' declares 'Map' here
// DIAG-NEXT: {{.*}}:11:5: note [I900N]: 'Map' is required here
// END-GENERATED-CHECKS(DIAG)
