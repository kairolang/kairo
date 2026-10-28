// A value of an associated type has no variants, fields or values a
// pattern could test, as a bounded parameter's value has none
// (interfaces.md, Generic Bodies): `match` can bind it, guard it or ignore
// it, and a literal pattern is an error naming the associated type. The
// binding and the wildcard stay silent.

interface Store {
    type Item
    fn get(const self) -> Self::Item
}

fn <T impl Store> look(s: T) -> i32 {
    var x = s.get()
    var a = match x {
        case 3 => 1
        default => 0
    }
    var b = match x {
        case var v => 2
    }
    var c = match x {
        case _ => 3
    }
    return a + b + c
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:15:14: error [SC001E]: a value of type 'T::Item' can only be matched by a binding, '_' or 'default' (with a 'where' guard)
// DIAG-NEXT: {{.*}}:8:5: note [I900N]: 'T::Item' is an associated type: no bound gives it variants, fields or values a pattern could test
// END-GENERATED-CHECKS(DIAG)
