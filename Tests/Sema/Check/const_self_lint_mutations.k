// -Wconst-self: every way a method writes its object keeps SC273W quiet
// (m1..m7: a nested field, an element, ++, an @inout argument, assignment,
// the address escaping, a closure), and reads stay warned (r1..r4: a
// range-for over a field, an f-string, a const method, a nested field).

struct P { var x: i32 = 0 }
fn take(@inout v: i32) { v = 1 }

class C {
    var n: i32 = 0
    var p: P
    var v: [i32]
    var s: string = "a"
    fn m1(self) { self.p.x += 1 }
    fn m2(self) { self.v[0] = 1 }
    fn m3(self) { ++self.n }
    fn m4(self) { take(&self.n) }
    fn m5(self) { self.s = self.s + "b" }
    fn m6(self) -> *i32 { return &self.n }
    fn m7(self) { var f = fn () { self.n = 1 }; f() }
    fn m8(self) { self.v.clear() }
    fn r1(self) -> i32 { var t = 0; for x in self.v { t += x }; return t }
    fn r2(self) -> string { return f"{self.n}" }
    fn r3(self) -> usize { return self.s.length() }
    fn r4(self) -> i32 { return self.p.x }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -Wconst-self 2>&1 || true; } | %FileCheck %s --implicit-check-not=SC273W --implicit-check-not=SC274W --implicit-check-not=error
// CHECK: const_self_lint_mutations.k:22:11: warning [SC273W]: method 'r1' never mutates 'self'; declare it 'const self'
// CHECK: const_self_lint_mutations.k:23:11: warning [SC273W]: method 'r2' never mutates 'self'; declare it 'const self'
// CHECK: const_self_lint_mutations.k:24:11: warning [SC273W]: method 'r3' never mutates 'self'; declare it 'const self'
// CHECK: const_self_lint_mutations.k:25:11: warning [SC273W]: method 'r4' never mutates 'self'; declare it 'const self'
