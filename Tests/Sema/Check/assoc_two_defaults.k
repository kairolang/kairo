// Two interfaces a type declares each give one inherited associated type a
// default, and the defaults differ: which one applies would depend on the
// path (interfaces.md, "Associated types and inheritance"), so neither
// does and the conformance fails, naming both. Declaring the type in the
// conformer (`Both`) chooses; equal defaults (`Same`) agree; one default
// alone (`One`) applies. The first one found used to win silently, for
// every interface of the type, D2's row included.

interface G { type Node }
interface D1 derives G { type Node = i64 }
interface D2 derives G { type Node = i32 }
interface D3 derives G { type Node = i64 }

class Split impl D1, D2 {
    fn Split(self) { }
}
class Both impl D1, D2 {
    type Node = i8
    fn Both(self) { }
}
class Same impl D1, D3 {
    fn Same(self) { }
}
class One impl D2 {
    fn One(self) { }
}

fn <T impl G> node(t: T) -> i32 { return 0 }

fn main() -> i32 {
    var a = node(Split())
    var b = node(Both())
    var c = node(Same())
    var d = node(One())
    return 0
}

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:31:13: error [SC001E]: 'Split' does not conform to 'G': its interfaces give associated type 'Node' two defaults, 'i64' from 'D1' and 'i32' from 'D2'
// DIAG-NEXT: {{.*}}:28:5: note [I900N]: required by this bound
// DIAG-NEXT: {{.*}}:10:38: note [I900N]: 'D1' gives it 'i64' here
// DIAG-NEXT: {{.*}}:11:38: note [I900N]: 'D2' gives it 'i32' here; declare 'type Node = ...' in 'Split' to choose
// END-GENERATED-CHECKS(DIAG)
