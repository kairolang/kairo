// interfaces.md, Defaults: "A default must satisfy its own bounds. This is
// checked once, at the interface declaration, with Self abstract, not
// separately for each conforming type." It was not checked at all: the
// interface was accepted, and an explicit conformer taking the default
// then failed the associated type's bound at its use instead.
//
// A concrete default is checked by conformance; a default that is another
// associated type (`= Self::Node`) holds exactly when that type's own
// bounds grant the interface -- with Self abstract they are all it is
// known to have.

interface Display { fn show(const self) -> i32 }

class Shown {
    fn show(const self) -> i32 { return 1 }
}

interface Bad {
    type Item impl Display = i32
}

interface Good {
    type Item impl Display = Shown
}

interface Unbounded {
    type Node
    type Edge impl Display = Self::Node
}

interface Bounded {
    type Node impl Display
    type Edge impl Display = Self::Node
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:19:30: error [SC001E]: the default of associated type 'Item' is 'i32', which does not meet its bound 'Display'
// DIAG-NEXT: {{.*}}:19:10: note [I900N]: the bound is declared here
// DIAG: {{.*}}:28:30: error [SC001E]: the default of associated type 'Edge' is 'Self::Node', which does not meet its bound 'Display'
// DIAG-NEXT: {{.*}}:28:10: note [I900N]: the bound is declared here
// END-GENERATED-CHECKS(DIAG)
