// Purity inference (on by default) and an implicit conversion: the call of
// `@implicit op as` has no node on the lowered tree (EmitIR spells it as a
// cast), so before it was recorded (SemaContext::implicit_convs) `through`
// was stamped const while its conversion writes a global, and clang at -O2
// merged the two calls in main into one: `hits` came out 1. `clean`
// converts through a @pure operator and is inferred pure.

var hits: i32 = 0

struct Bumps {
    var x: i32
    @implicit fn op as (const self) -> i32 { hits = hits + 1; return self.x }
}

struct Reads {
    var x: i32
    @implicit @pure fn op as (const self) -> i32 { return self.x }
}

fn eats(x: i32) -> i32 { return x }

fn through(b: Bumps) -> i32 { return eats(b) }
fn clean(r: Reads) -> i32 { return eats(r) }

fn main() -> i32 {
    var b = Bumps { x: 3 }
    var s = through(b) + through(b) + clean(Reads { x: 1 })
    return if (s == 7 && hits == 2) => (0) else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -finfer-purity --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: {{(const|pure)\)\)}} signed int through(
// CXX: __attribute{{(__)?}}((pure)) signed int clean(
// CXX-NOT: {{(const|pure)\)\)}} signed int through(

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -O2 -o %t.exe --cache-dir %t.d/run
// RUN: %t.exe
