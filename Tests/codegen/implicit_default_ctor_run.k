// A record that declares no constructor has the implicit default one
// (interfaces-requirements.mdx: "A type that declares no constructor at all
// has the implicit one"; classes-lifecycle.mdx: "Anything not written is
// compiler-generated") when every base and field can be built from
// nothing. So `var x: R`, `[R; N]`, `R()` and a field of type R with no
// initializer all work, numbers are zero and initializers apply. Covered:
// a struct, a class (private fields), a generic record, records nested by
// value, a field whose record declares its own default constructor, a base
// class, and a constructor requirement met by the implicit constructor.

struct F { var n: i32  var m: i64 = 4 }
class G {
    var n: i32
    var f: f64 = 1.5
    fn get(self) -> i32 { return self.n + (self.f as i32) }
}
class <T> Bare { pub var v: T  pub var w: i32 = 2 }
struct Inner { var a: i32 = 7  var b: u8 }
struct Outer { var i: Inner  var arr: [Inner; 2]  var k: i32 }
class Declared {
    pub var d: i32
    fn Declared(self) { self.d = 11 }
}
class HasDeclared { pub var x: Declared  pub var y: i32 }
class Base { pub var b: i32 = 20 }
class Child derives Base { pub var c: i32 }

interface Defaultable { fn Defaultable(self) }
fn <T impl Defaultable> fresh() -> T { return T() }
struct Plain impl Defaultable { var p: i32 = 13 }

fn main() -> i32 {
    var y: F
    var x: [F; 6]
    if (y.n != 0) || (y.m != 4) || (x[5].n != 0) || (x[0].m != 4) { return 1 }
    var g: G
    if g.get() != 1 { return 2 }
    var b: Bare<i32>
    if (b.v != 0) || (b.w != 2) { return 3 }
    var o: Outer
    if (o.i.a != 7) || (o.i.b != 0) || (o.arr[1].a != 7) || (o.k != 0) { return 4 }
    var h: HasDeclared
    if (h.x.d != 11) || (h.y != 0) { return 5 }
    var c: Child
    if (c.b != 20) || (c.c != 0) { return 6 }
    var f2 = F()
    if f2.m != 4 { return 7 }
    var pl = fresh<Plain>()
    if pl.p != 13 { return 8 }
    return 0
}

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error [
// DIAG-NOT: warning [
// END-GENERATED-CHECKS(DIAG)

// BEGIN-GENERATED-CHECKS(EXEC) mode=run -- regenerate with Tests/gen_checks.py, do not hand-edit
// REQUIRES: clang
// RUN: rm -rf %t.exec.d
// RUN: %kairo %s -o %t.exec.exe --cache-dir %t.exec.d
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 0
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
