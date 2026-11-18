// RUN: rm -f %t.exe
// An impure `@implicit op as` reached through a local initializer, a
// return and an argument keeps its caller impure under purity inference:
// each wrapper is called twice and clang at -O2 must not merge the calls.
// The conversion runs six times in all; the @pure one is free to be merged.

var hits: i32 = 0

struct Bumps {
    var x: i32
    @implicit fn op as (const self) -> i32 { hits = hits + 1; return self.x }
}

fn via_local(b: Bumps) -> i32 {
    var v: i32 = b
    return v
}
fn via_return(b: Bumps) -> i32 { return b }
fn eats(x: i32) -> i32 { return x }
fn via_arg(b: Bumps) -> i32 { return eats(b) }

fn main() -> i32 {
    var b = Bumps { x: 1 }
    var s = via_local(b) + via_local(b) + via_return(b) + via_return(b) + via_arg(b) + via_arg(b)
    return if (s == 6 && hits == 6) => 0 else => 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -finfer-purity -O0 -o %t.exe --cache-dir %t.d/o0
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo %s -finfer-purity -O2 -o %t.exe --cache-dir %t.d/o2
// RUN: %t.exe
