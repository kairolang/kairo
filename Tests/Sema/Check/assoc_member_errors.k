// A value of an associated type has exactly the members its own bounds
// declare (interfaces.md, Generic Bodies), as a bounded parameter does:
// a name none of them declares is R025E, and an associated type with no
// bound has no members at all (R051E, note at its declaration). The
// working side is
// Tests/Codegen/witness/assoc_type_member.k.

interface Display { fn show(const self) -> i32 }

interface Store {
    type Item impl Display
    type Raw
    fn get(const self) -> Self::Item
    fn raw(const self) -> Self::Raw
}

fn <T impl Store> f(s: T) -> i32 {
    var x: T::Item = s.get()
    var a = x.hide()
    var r: T::Raw = s.raw()
    var b = r.show()
    return x.show()
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:19:15: error [R025E]: no member named 'hide' in the bounds of 'T::Item'
// DIAG: {{.*}}:21:15: error [R051E]: 'T::Raw' has no members, so 'show' cannot be resolved
// DIAG-NEXT: {{.*}}:12:5: note [R051N]: the associated type is declared with no bound; add 'impl <Interface>' to give it members
// END-GENERATED-CHECKS(DIAG)
