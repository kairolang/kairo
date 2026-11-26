// An `op as` to one target declared in more than one place is an error at
// each use, explicit or implicit, naming both places: the type's body and
// an extension in the using file, or extensions in two imported files.
// Extensions in different files are different member lists, so neither
// declaration alone is an error; two blocks of one file are one member
// list, and a repeat there is R041E (redecl_merge/extension_member_twice.k).

import self::types::*
import self::ext_a::*
import self::ext_b::*

extend Feet {
    @implicit pub fn op as (const self) -> M { return M{v: self.v * 2} }
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
// CHECK-NOT: R041E
// CHECK: ambiguous.k:21:18: error [SC340E]: the conversion from 'Feet' to 'M' is ambiguous: the type's body and an extension both declare it
// CHECK-NEXT: types.k:6:19: note [SC340N]: one 'op as' is declared here
// CHECK-NEXT: ambiguous.k:13:19: note [SC340N]: another is declared here
// CHECK: ambiguous.k:22:13: error [SC340E]: the conversion from 'Feet' to 'M' is ambiguous: the type's body and an extension both declare it
// CHECK: ambiguous.k:23:19: error [SC340E]: the conversion from 'Feet' to 'N' is ambiguous: two extensions both declare it
// CHECK-NEXT: ext_a.k:4:19: note [SC340N]: one 'op as' is declared here
// CHECK-NEXT: ext_b.k:4:19: note [SC340N]: another is declared here
// CHECK: ambiguous.k:24:13: error [SC340E]: the conversion from 'Feet' to 'N' is ambiguous: two extensions both declare it
// CHECK-NOT: R041E
