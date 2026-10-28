// `a + b` derived from an `op +=` a bound grants: copy `a`, `+=` `b`
// through the witness, yield the copy. Was an ICE in OperatorLowering
// ("derived `+` on an untyped node"): the operator resolved, but the node
// carries its operand's dependence and the typer read that as "deferred"
// and left the node untyped. Found by the `derives`-bound operator batch
// (oop/derives_bound_operators.k has the base-class half).

import std::io::println

pub interface Addable {
    fn op += (self, o: i32)
}

class Acc impl Addable {
    pub var v: i32 = 0
    fn op += (self, o: i32) { self.v += o; }
}

fn <T impl Addable> plus(a: T) -> T { return a + 4; }
fn <T impl Addable> twice(a: T) -> T { return (a + 1) + 2; }

fn main() -> i32 {
    var a = Acc()
    a += 10
    var b = plus(a)
    var c = twice(b)
    println(f"{a.v} {b.v} {c.v}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 10 14 17
