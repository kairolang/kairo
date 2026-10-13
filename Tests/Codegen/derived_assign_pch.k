// A TU that loads its ffi headers as a precompiled set gets <new> another
// way than one that loads none: the PCH reader rebuilds the predefines, so
// the header goes in through the preprocessor's include list. M's derived
// `op =` must still find the global placement new; <stdint.h> declares
// none.

ffi "c++" import "stdint.h"

var moves: i32 = 0
var drops: i32 = 0

class M {
    pub var v: i32
    pub fn M(self, v: i32) { self.v = v }
    @move
    fn M(self, other: Self) {
        self.v = other.v
        moves = moves + 1
    }
    fn op delete(self) { drops = drops + 1 }
}

fn main() -> i32 {
    var w: int32_t = 2
    var m = M(1)
    m = M(5)
    if (moves == 1) && (drops == 2) && (m.v == 5) { return w + 5 }
    return 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: %kairo %s -c --cache-dir %t.d/k
// RUN: %clangxx %t.d/k/*.o %t.d/k/builtin/*.o %t.d/k/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
