// An operator, a conversion or a null test on a value of an associated
// type is what its own bounds grant, as on a bounded parameter
// (interfaces.md, Generic Bodies; MONO.md D0): R051E when it has no bound,
// R025E when it has bounds and none declares the requirement. These used to
// be left for C++ to decide per instance (`r == r`, `a + b` typed
// silently). An interpolation (`f"{r}"`) is the exception: with no bound
// granting a string it is formatted per instance (USER 2026-11-03,
// FormatHole::deferred), so `e3` is silent. `a == b` with `type Item impl
// Eq` is legal and stays silent; the working side is
// Tests/Codegen/witness/assoc_ops.k.

interface Eq { fn op ==(const self, o: Self) -> bool }
interface Store {
    type Item impl Eq
    type Raw
    fn get(const self) -> Self::Item
    fn raw(const self) -> Self::Raw
}

fn <T impl Store> ops(s: T) -> bool {
    var a = s.get()
    var b = s.get()
    var r = s.raw()
    var e1 = r == r
    var e2 = a + b
    var e3 = f"{r}"
    var e4 = a as i32
    var e5 = -a
    var e6 = a == null
    return a == b
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:24:14: error [R051E]: '==' on 'T::Raw' needs a bound that declares 'op =='
// DIAG-NEXT: {{.*}}:15:5: note [R051N]: 'Raw' is declared with no bound
// DIAG: {{.*}}:25:14: error [R025E]: '+' on 'T::Item' needs a bound that declares 'op +' or 'op +='; none of the bounds of 'Item' does
// DIAG-NEXT: {{.*}}:14:5: note [I900N]: 'Item' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:27:14: error [R025E]: 'as i32' on 'T::Item' needs a bound that declares 'op as' returning 'i32'; none of the bounds of 'Item' does
// DIAG-NEXT: {{.*}}:14:5: note [I900N]: 'Item' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:28:14: error [R025E]: '-' on 'T::Item' needs a bound that declares 'op -'; none of the bounds of 'Item' does
// DIAG-NEXT: {{.*}}:14:5: note [I900N]: 'Item' is declared here; add the requirement to one of its interfaces, or bound it by one that declares it
// DIAG: {{.*}}:29:14: error [SC260E]: 'a' is not nullable; 'T::Item' is never null, so comparing it with 'null' is meaningless
// DIAG-NEXT: {{.*}}:21:5: note [I900N]: declared 'T::Item' here; a type that may be null is written 'T?'
// END-GENERATED-CHECKS(DIAG)
