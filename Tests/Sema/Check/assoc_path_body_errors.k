// What a body may not name through an associated type it names correctly
// (interfaces.md, Generic Bodies: a body uses exactly what its bounds
// declare, an associated type's own bounds included). Each is diagnosed at
// the use, as the same misuse on a bounded parameter is: a static none of
// the associated type's bounds declares (R025E), and an instance member
// named with `::` (R027E). `T::Item::make()` is legal and stays silent
// (Tests/Codegen/witness/assoc_static_member.k). Operators on such a value
// are assoc_ops_errors.k.

interface Make {
    static fn make() -> Self
    fn val(const self) -> i32
}
interface Store {
    type Item impl Make
}

fn <T impl Store> statics(s: T) -> i32 {
    var a = T::Item::build()
    var b = T::Item::val()
    var c = T::Item::make()
    return c.val()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:19:22: error [R025E]: no member named 'build' in the bounds of 'T::Item'
// DIAG: {{.*}}:20:22: error [R027E]: 'val' is an instance member of the bounds of 'T::Item'; use '.' on a value of 'T::Item'
// END-GENERATED-CHECKS(DIAG)
