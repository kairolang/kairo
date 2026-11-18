// An `op as` to one target declared in two places is an error at the use,
// explicit or implicit, naming both: the type's body and an extension, or
// two extensions. A member is not replaced by an extension, and neither
// extension outranks the other.

struct M { var v: i32 }
struct N { var v: i32 }

struct Feet {
    var v: i32
    @implicit fn op as (const self) -> M { return M{v: self.v} }
}

extend Feet {
    @implicit fn op as (const self) -> M { return M{v: self.v * 2} }
    @implicit fn op as (const self) -> N { return N{v: 1} }
}

extend Feet {
    @implicit fn op as (const self) -> N { return N{v: 2} }
}

fn take(m: M) -> i32 { return m.v }
fn taken(m: N) -> i32 { return m.v }

fn main() -> i32 {
    var f = Feet{v: 1}
    var a = take(f)
    var b = f as M
    var c = taken(f)
    var d = f as N
    return a + b.v + c + d.v
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: ext_op_as_ambiguous.k:28:18: error [SC340E]: the conversion from 'Feet' to 'M' is ambiguous: the type's body and an extension both declare it
// CHECK-NEXT: ext_op_as_ambiguous.k:11:15: note [SC340N]: one 'op as' is declared here
// CHECK-NEXT: ext_op_as_ambiguous.k:15:15: note [SC340N]: another is declared here
// CHECK: ext_op_as_ambiguous.k:29:13: error [SC340E]: the conversion from 'Feet' to 'M' is ambiguous: the type's body and an extension both declare it
// CHECK: ext_op_as_ambiguous.k:30:19: error [SC340E]: the conversion from 'Feet' to 'N' is ambiguous: two extensions both declare it
// CHECK-NEXT: ext_op_as_ambiguous.k:16:15: note [SC340N]: one 'op as' is declared here
// CHECK-NEXT: ext_op_as_ambiguous.k:20:15: note [SC340N]: another is declared here
// CHECK: ext_op_as_ambiguous.k:31:13: error [SC340E]: the conversion from 'Feet' to 'N' is ambiguous: two extensions both declare it
