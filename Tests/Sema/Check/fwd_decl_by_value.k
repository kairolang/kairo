// A record that is only ever forward-declared has no layout: it may be used
// through a pointer, never by value. A field holding it (directly, in an
// array, through a nullable, as a base) is the C++ "field has incomplete
// type", reported where the field is, with a note at the forward
// declaration and, for a field typed exactly the record, a fix-it making it
// a pointer. A local or a call that would build one is told the record is
// only forward-declared rather than that it lacks a default constructor.
// A record defined later in the file is complete, and every pointer use is
// fine.

struct Never
union NeverU
class NeverC

struct Holds {
    pub var a: Never
    pub var b: [NeverU; 2]
    pub var c: unsafe *Never        // ok: a pointer
    pub var d: NeverC?
}

class Derived derives NeverC { }

struct Later
struct UsesLater { pub var l: Later }   // ok: Later is defined below
struct Later { pub var n: i32 }

fn takes(p: unsafe *Never) -> i32 { return 0 }   // ok

fn main() -> i32 {
    var x: Never
    var y = NeverC()
    var z: unsafe *NeverU = &null           // ok
    var u = UsesLater{l: Later{n: 4}}
    return u.l.n
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:16:9: error [SC001E]: 'Holds' holds 'Never' by value, but 'Never' is only forward-declared, so its size is unknown
// DIAG-NEXT: fix-it:"{{.*}}":{16:16-16:16}:"unsafe *"
// DIAG-NEXT: {{.*}}:11:1: note [SC001N]: 'Never' is forward-declared here and never defined
// DIAG: {{.*}}:17:9: error [SC001E]: 'Holds' holds 'NeverU' by value, but 'NeverU' is only forward-declared, so its size is unknown
// DIAG-NEXT: {{.*}}:12:1: note [SC001N]: 'NeverU' is forward-declared here and never defined
// DIAG: {{.*}}:19:9: error [SC001E]: 'Holds' holds 'NeverC' by value, but 'NeverC' is only forward-declared, so its size is unknown
// DIAG-NEXT: {{.*}}:13:1: note [SC001N]: 'NeverC' is forward-declared here and never defined
// DIAG: {{.*}}:22:23: error [SC001E]: 'Derived' holds 'NeverC' by value, but 'NeverC' is only forward-declared, so its size is unknown
// DIAG-NEXT: {{.*}}:13:1: note [SC001N]: 'NeverC' is forward-declared here and never defined
// DIAG: {{.*}}:31:5: error [SC001E]: 'x' is declared without an initializer, and 'Never' is only forward-declared, so there is nothing to build; Kairo has no uninitialized variables
// DIAG-NEXT: fix-it:"{{.*}}":{31:17-31:17}:" = ..."
// DIAG: {{.*}}:32:13: error [SC001E]: 'NeverC()' cannot be called: 'NeverC' is only forward-declared, so there is nothing to build
// DIAG-NEXT: {{.*}}:13:1: note [SC001N]: 'NeverC' declared here
// END-GENERATED-CHECKS(DIAG)
