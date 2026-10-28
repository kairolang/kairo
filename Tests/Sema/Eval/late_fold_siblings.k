// Declarations in sibling branches of an `eval if` that waits for a type
// fact (EVAL.md 4.2b): N(a) and RedeclMerge see every branch until the late
// fold keeps one, and two declarations that never coexist are neither a
// redefinition nor one entity. A use bound before the fold -- WORD_BITS,
// width(), get() -- is bound again to the survivor.
eval if sizeof usize >= 8 {
    eval WORD_BITS = 64
    fn width() -> i32 { return 64 }
} else {
    eval WORD_BITS = 32
    fn width() -> i32 { return 32 }
}

struct Plain { var x: i32 }

class Cell {
    eval if is_trivially_copyable!(Plain) {
        var v: i64
        fn get(self) -> i64 { return self.v }
    } else {
        var v: i32
        fn get(self) -> i64 { return self.v as i64 }
    }
    fn Cell(self) { self.v = 7 }
}

fn main() -> i32 {
    var k = Cell()
    if WORD_BITS != width() { return 1 }
    return (k.get() as i32) - 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
