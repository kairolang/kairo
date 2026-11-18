// What follows `derives` on a class is a class that is not `final`
// (classes-inheritance.mdx): a primitive, a pointer, an enum, a union, a
// Kairo struct and an interface are SC353E at the edge, the interface with
// the `impl` spelling it wants. A base that is only forward-declared is
// SC227E. A class, an alias of one, a generic instance, a dependent base, a
// type-parameter base and a `priv` edge are accepted.

struct SomeStruct { var a: i32 = 0 }
interface SomeInterface { fn f(self) -> i32 }
final class FinalClass { }
class Fwd
enum Color { Red, Green }
union U { var a: i32  var b: f32 }
class Ok { pub var k: i32 = 0 }
class <T> Gen { pub var t: T }
type OkAlias = Ok

class A1 derives i32 { }
class A2 derives SomeInterface { }
class A3 derives SomeStruct { }
class A4 derives FinalClass { }
class A5 derives Fwd { }
class A6 derives Color { }
class A7 derives U { }
class A8 derives *Ok { }
class A9 derives Ok, FinalClass { }

class B1 derives Ok { }
class B2 derives OkAlias { }
class B3 derives Gen<i32> { }
class <T> B4 derives Gen<T> { }
class <A derives Ok> B5 derives A { }
class B6 derives priv Ok { }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: {{.*}}:18:18: error [SC353E]: 'A1' cannot derive 'i32': 'i32' is not a class
// CHECK: {{.*}}:19:18: error [SC353E]: 'A2' cannot derive 'SomeInterface': 'SomeInterface' is an interface; a class conforms to an interface with 'impl': 'class A2 impl SomeInterface'
// CHECK-NEXT: {{.*}}:9:11: note [SC353N]: 'SomeInterface' is declared here
// CHECK: {{.*}}:20:18: error [SC353E]: 'A3' cannot derive 'SomeStruct': 'SomeStruct' is a struct; a class derives a class, and holds a struct as a field
// CHECK-NEXT: {{.*}}:8:8: note [SC353N]: 'SomeStruct' is declared here
// CHECK: {{.*}}:21:18: error [SC353E]: 'A4' cannot derive 'FinalClass': 'FinalClass' is final
// CHECK-NEXT: {{.*}}:10:13: note [SC353N]: 'FinalClass' is declared here
// CHECK: {{.*}}:22:18: error [SC227E]: 'A5' holds 'Fwd' by value, but 'Fwd' is only forward-declared, so its size is unknown
// CHECK: {{.*}}:23:18: error [SC353E]: 'A6' cannot derive 'Color': 'Color' is not a class
// CHECK: {{.*}}:24:18: error [SC353E]: 'A7' cannot derive 'U': 'U' is not a class
// CHECK: {{.*}}:25:18: error [SC353E]: 'A8' cannot derive '*Ok': '*Ok' is not a class
// CHECK: {{.*}}:26:22: error [SC353E]: 'A9' cannot derive 'FinalClass': 'FinalClass' is final
