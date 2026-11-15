// An interface is a set of requirements, not a type of values
// (interfaces.mdx): named where a value's type goes it is SC332E, at the
// type. Through a pointer it is virtual interface dispatch, which is not
// compiled yet (SC116E). As a bound it is what it is for.

interface HasF {
    fn f(const self) -> i32
}

class S impl HasF {
    fn f(const self) -> i32 { return 1 }
}

fn <T> size_of() -> usize { return sizeof T }

fn by_value(x: HasF) -> i32 { return 0 }
fn local() {
    var v: [HasF]
}
fn ret() -> HasF? { return null }
fn sizes() -> usize { return sizeof HasF + size_of<HasF>() }
fn trait() -> bool { return __builtin_is_trivially_copyable<HasF>() }
fn ptr(p: *HasF) -> i32 { return 0 }

class Field { var h: HasF }

fn <T impl HasF> bounded(x: T) -> i32 { return x.f() }

fn main() -> i32 { return bounded(S()) }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: interface_not_a_type.k:16:16: error [SC332E]: 'HasF' is an interface, not a type; it can only bound a generic parameter (`T impl HasF`)
// CHECK: interface_not_a_type.k:18:12: error [SC332E]: 'HasF' is an interface
// CHECK: interface_not_a_type.k:20:13: error [SC332E]: 'HasF' is an interface
// CHECK: interface_not_a_type.k:21:37: error [SC332E]: 'HasF' is an interface
// CHECK: interface_not_a_type.k:21:52: error [SC332E]: 'HasF' is an interface
// CHECK: interface_not_a_type.k:22:61: error [SC332E]: 'HasF' is an interface
// CHECK: interface_not_a_type.k:23:11: error [SC116E]: a pointer to the interface 'HasF' (virtual interface dispatch) is not yet supported
// CHECK: interface_not_a_type.k:25:22: error [SC332E]: 'HasF' is an interface
// CHECK-NOT: {{error|Internal Compiler Error}}
