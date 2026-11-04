// Arithmetic over untyped integer literals is still untyped: as an
// argument it takes the type its parameter asks for, as one literal does
// (primitives.md §5, a parameter is an expected type). `Arena(256 * 1024)`
// against `blk_sz: usize` was SC063E, the product stuck at i32.

class Arena {
    pub var n: usize = 0;
    fn Arena(self, blk_sz: usize) { self.n = blk_sz; }
}

fn take(x: usize) -> usize { return x; }
fn small(x: u8) -> u8 { return x; }

fn f() -> usize {
    var a = Arena(256 * 1024);
    var b = take((1 << 20) - 1);
    var c = take(6 / 2 % 2);
    var d = small(200 + 100);
    return a.n + b + c;
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: literal_arith_argument.k:18:13: error [SC063E]: no matching overload for call to 'small'
