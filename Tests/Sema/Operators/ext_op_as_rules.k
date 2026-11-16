// `op as` may be declared in an extension, with or without `@implicit`.
// What stays as it was: `[]` and `finally` are member-only, `@implicit`
// goes on an `op as` only, and conversions never chain (A -> B and B -> C
// do not make A -> C).

struct A { var v: i32 }
struct B { var v: i32 }
struct C { var v: i32 }

extend A { @implicit fn op as (const self) -> B { return B{v: self.v} } }
extend B { @implicit fn op as (const self) -> C { return C{v: self.v} } }
extend A { fn op as (const self) -> i64 { return 7 } }
extend A { fn op [] (const self, i: i32) -> i32 { return i } }
extend A { fn op finally (self) {} }
extend A { @implicit fn plain(const self) -> i32 { return 1 } }

fn takeb(b: B) -> i32 { return b.v }
fn takec(c: C) -> i32 { return c.v }

fn main() -> i32 {
    var a = A{v: 1}
    var n: i64 = a          // not @implicit: needs `as`
    return takeb(a) + takec(a)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: ext_op_as_rules.k:13:12: error [SC055E]: 'op []' cannot be declared in an extension; it must be a member, so declare it in the type's body
// CHECK: ext_op_as_rules.k:14:12: error [SC055E]: 'op finally' cannot be declared in an extension; it must be a member, so declare it in the type's body
// CHECK: ext_op_as_rules.k:15:22: error [SC115E]: '@implicit' applies only to a conversion operator: 'fn op as (self) -> T' in a type's body or an extension
// CHECK: ext_op_as_rules.k:22:18: error [SC028E]: cannot convert 'A' to 'i64'
// CHECK: ext_op_as_rules.k:23:23: error [SC063E]: no matching overload for call to 'takec'
// CHECK: cannot convert argument of type 'A' to parameter 'c' of type 'C'
