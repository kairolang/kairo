// An out-of-line definition of a marked `++` / `--` finds its in-class
// declaration: the member table keys an operator without the `l` / `r`
// marker, and prefix and postfix are told apart by signature. A second
// out-of-line definition of the same one is a redefinition, and a marked
// definition whose fixity has no declaration matches nothing.

struct C {
    var x: i32
    fn op l++(self) -> C
    fn op r++(self) -> C
    fn op l--(self) -> C
}

fn C::op l++(self) -> C { return C{ x: self.x + 1 } }
fn C::op r++(self) -> C { return C{ x: self.x + 2 } }
fn C::op l--(self) -> C { return C{ x: self.x - 1 } }
fn C::op l--(self) -> C { return C{ x: self.x - 2 } }
fn C::op r--(self) -> C { return C{ x: self.x - 3 } }

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{:1[45]:.*}}error
// DIAG: {{.*}}:17:1: error [R029E]: redefinition of 'op --'
// DIAG: {{.*}}:16:1: note [R029N]: previous definition of 'op --' is here
// DIAG: {{.*}}:18:1: error [R031E]: out-of-line definition of 'op --' does not match any declaration in 'C'
// DIAG-NOT: error
