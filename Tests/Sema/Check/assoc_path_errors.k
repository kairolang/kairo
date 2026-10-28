// A name reached through an associated type in TYPE position is looked up
// in that associated type's own bounds, as one reached through a parameter
// is in the parameter's (interfaces.md, Generic Bodies; the working side is
// Tests/Codegen/witness/assoc_through_assoc.k). Each misuse is diagnosed at
// the segment that names it:
//  - a name none of the head's bounds declares (R025E, a note per bound);
//  - any name through an associated type with no bound (R025E, the note
//    at its declaration);
//  - a generic associated type without its arguments, or a plain one with
//    some (the generic-argument arity error, as for any template);
//  - the same through `Self::` inside the interface.

interface Show { fn show(const self) -> i32 }
interface Holder {
    type Inner impl Show
}
interface Store {
    type Item impl Holder
    type Raw
    type <K> Map
    fn bad(const self) -> Self::Item::Missing
}

fn <T impl Store> missing(s: T) -> T::Item::Nope { }
fn <T impl Store> unbounded(s: T) -> T::Raw::Inner { }
fn <T impl Store> noargs(s: T) -> T::Map { }
fn <T impl Store> extra(s: T) -> T::Item<i32> { }
fn <T impl Store> deep(s: T) -> T::Item::Inner::Deeper { }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:21:39: error [R025E]: no associated type named 'Missing' in the bounds of 'Self::Item'
// DIAG-NEXT: {{.*}}:18:10: note [I900N]: bound here
// DIAG: {{.*}}:24:45: error [R025E]: no associated type named 'Nope' in the bounds of 'T::Item'
// DIAG-NEXT: {{.*}}:18:10: note [I900N]: bound here
// DIAG: {{.*}}:25:46: error [R025E]: no associated type named 'Inner' in the bounds of 'T::Raw'
// DIAG-NEXT: {{.*}}:19:5: note [I900N]: 'T::Raw' is declared with no bound; add 'impl <Interface>' to give it associated types
// DIAG: {{.*}}:26:38: error [R032E]: 'Map' requires at least 1 generic argument(s), but 0 were given
// DIAG-NEXT: {{.*}}:20:5: note [R032N]: declared here
// DIAG: {{.*}}:27:37: error [R032E]: 'Item' is not generic and takes no generic arguments
// DIAG-NEXT: {{.*}}:18:5: note [R032N]: declared here
// DIAG: {{.*}}:28:49: error [R025E]: no associated type named 'Deeper' in the bounds of 'T::Item::Inner'
// DIAG-NEXT: {{.*}}:15:10: note [I900N]: bound here
// END-GENERATED-CHECKS(DIAG)
