// A C++ `constexpr` variable from an ffi header is a compile-time value,
// as a `constexpr` function's call is: an `eval` binding, a function-body
// `eval if`, an array length and a generic value argument read it. An
// integer one folds to the value clang computed, so `Buf<K_OUT>` is
// `Buf<4>`.
ffi "c++" import "consts.h"

import std::io

eval FLAGS:  u32 = K_IN | K_OUT
eval NEG:    i64 = K_NEG * 2
eval SCALE:  f64 = K_HALF * 4.0
eval MEMBER: i32 = Limits::MAX + 1
eval SQ:     i32 = sq(K_SIDE)

struct <eval N: u32> Buf {
    var n: u32 = N
}

fn main() -> i32 {
    var a: [u8; K_IN + 1]
    var b: [u8; Limits::MAX]
    var g: Buf<K_OUT>
    var h: Buf<4>            = g
    eval if K_NEG < 0 && sq(3) == 9 {
        io::println("folded")
    } else {
        io::println("not folded")
    }

    io::println(
        f"{FLAGS} {NEG} {SCALE} {MEMBER} {SQ} {a.size()} {b.size()} {h.n}",
    )

    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT: folded
// OUT-NEXT: 5 -10 2 9 9 2 8 4
