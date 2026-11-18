// A member type named through a deriving class in TYPE position reaches the
// base through the class's edge, as `Der::Inner{}` does in an expression
// (classes-inheritance.mdx): through a plain edge it keeps its own
// visibility, so a `priv` nested type stays private; through a `priv` or
// `prot` edge it is private or protected to the deriving class. A class
// deriving the `prot` edge's class names it.

import inputs::access_member_type_edge_lib::*

fn clean() -> i32 {
    var a: Open::Inner
    var b: Base::Inner
    var n: Open::Num = 1
    return a.k + b.k + n
}

fn priv_member() -> i32 {
    var h: Open::Hidden
    return 0
}

fn priv_edge() -> i32 {
    var i: Der::Inner
    var n: Der::Num = 0
    return n
}

fn prot_edge() -> i32 {
    var i: Pro::Inner
    return 0
}

class Sub derives Pro {
    fn Sub(self) { }
    fn reach(self) -> i32 {
        var i: Pro::Inner
        return i.k
    }
}

fn main() -> i32 {
    return clean() + lib_reads()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}access_member_type_through_edge.k:18:18: error [SC242E]: type 'Hidden' of 'Base' is private
// CHECK: {{.*}}access_member_type_edge_lib.k:5:16: note [SC242N]: 'Hidden' is declared private here
// CHECK: {{.*}}access_member_type_through_edge.k:23:17: error [SC242E]: 'Inner' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK-NEXT: {{.*}}access_member_type_edge_lib.k:10:23: note [SC242N]: 'Der' declares its base 'Base' 'priv' here, so the members of 'Base' are private to 'Der' and its file
// CHECK: {{.*}}access_member_type_through_edge.k:24:17: error [SC242E]: 'Num' is inaccessible through 'Der': 'Der' derives 'Base' as private
// CHECK: {{.*}}access_member_type_through_edge.k:29:17: error [SC242E]: 'Inner' is inaccessible through 'Pro': 'Pro' derives 'Base' as protected
// CHECK-NEXT: {{.*}}access_member_type_edge_lib.k:11:23: note [SC242N]: 'Pro' declares its base 'Base' 'prot' here, so the members of 'Base' are protected to 'Pro' and its file
