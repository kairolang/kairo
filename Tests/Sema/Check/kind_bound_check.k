// The kind bounds `T: class` / `struct` / `enum` / `union` restrict T to
// that category of declaration (generics.mdx), checked at every instance,
// written or deduced (SC292E): `fn <T: class> f(x: T)`
// rejects `f(1)`. A generic body passing its own
// parameter on is checked where it is instantiated.

class K { pub var v: i32 = 0 }
struct S { var v: i32 }
enum E { A, B }
union U { var i: i32; var f: f32 }

fn <T: class>  of_class(x: T) -> i32 { return 1 }
fn <T: struct> of_struct(x: T) -> i32 { return 2 }
fn <T: enum>   of_enum(x: T) -> i32 { return 3 }
fn <T: union>  of_union(x: T) -> i32 { return 4 }
fn <T: class>  relay(x: T) -> i32 { return of_class(x) }

class <T: struct> Holder { pub var t: T }

fn main() -> i32 {
    var k = K()
    var s = S { v: 1 }
    var u = U { i: 1 }
    var r = of_class(k) + of_struct(s) + of_enum(E::A) + of_union(u) + relay(k)
    r += of_class(1)
    r += of_struct(k)
    r += of_enum(s)
    r += of_union(E::B)
    var h = Holder<K>()
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not="warning ["
// CHECK-DAG: kind_bound_check.k:25:10: error [SC292E]: 'i32' is not a class, so it cannot be 'T'
// CHECK-DAG: kind_bound_check.k:26:10: error [SC292E]: 'K' is not a struct, so it cannot be 'T'
// CHECK-DAG: kind_bound_check.k:27:10: error [SC292E]: 'S' is not an enum, so it cannot be 'T'
// CHECK-DAG: kind_bound_check.k:28:10: error [SC292E]: 'E' is not a union, so it cannot be 'T'
// CHECK-DAG: kind_bound_check.k:29:13: error [SC292E]: 'K' is not a struct, so it cannot be 'T'
