// `op as` overloaded on its target (casting.mdx, User-Defined
// Conversions), beyond op_as_overloads.k's two: three explicit targets one
// of them a record, `@implicit` ones picked by the parameter they meet
// (an exact match each, so no ambiguity), and a generic class whose
// conversions are to its parameter and to a fixed type.

class Meters {
    pub var v: i32
    fn Meters(self, v: i32) { self.v = v }
}

class Temp {
    var c: i32
    fn Temp(self, c: i32) { self.c = c }
    fn op as(self) -> i32 { return self.c }
    fn op as(self) -> i64 { return self.c * 2 }
    fn op as(self) -> Meters { return Meters(self.c * 3) }
}

class Level {
    var n: i32
    fn Level(self, n: i32) { self.n = n }
    @implicit fn op as(const self) -> i64 { return self.n + 1 }
    @implicit fn op as(const self) -> f64 { return self.n + 2 }
}

fn wide(x: i64) -> i32 { return x as i32 }
fn real(x: f64) -> i32 { return x as i32 }

class <T> Wrap {
    var t: T
    var tag: i32
    fn Wrap(self, t: T, tag: i32) { self.t = t; self.tag = tag }
    fn op as(self) -> T { return self.t }
    fn op as(self) -> i32 { return self.tag }
}

fn main() -> i32 {
    var t = Temp(10)
    var a = t as i32                    // 10
    var b = t as i64                    // 20
    var m = t as Meters                 // 30
    var l = Level(4)
    var w = wide(l)                     // 5
    var r = real(l)                     // 6
    var wr = Wrap<i64>(100, 7)
    var x = wr as i64                   // 100
    var y = wr as i32                   // 7
    return a + (b as i32) + m.v + w + r + (x as i32) + y - 100   // 78
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
// RUN: %t.exec.exe > %t.exec.out; test $? -eq 78
// RUN: test ! -s %t.exec.out
// END-GENERATED-CHECKS(EXEC)
