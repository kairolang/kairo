// The preprocessor's diagnostics come out in one order on every run, at
// any thread count, and an error limit keeps the same ones.
//
// part0.k .. part9.k import vec.k and not each other, so the walk runs them in
// one wave, side by side, and each reports the compile_error! it expands
// (R010E). Reported straight to the engine they printed in the order the
// walks finished, and --cmax-errors=5 kept whichever five came first. Each
// walk now reports into its own sink, drained in the wave's dispatch order
// once the wave is done (WaveExecutor::run).
//
// Each parallel run is compared with the one-thread run, byte for byte.

import self::part0::*
import self::part1::*
import self::part2::*
import self::part3::*
import self::part4::*
import self::part5::*
import self::part6::*
import self::part7::*
import self::part8::*
import self::part9::*

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --threads=1 --cmax-errors=5 2>&1 || true; } > %t.one
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p1
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p2
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p3
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p4
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p5
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p6
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p7
// RUN: { %kairo %s --type-check-only --threads=16 --cmax-errors=5 2>&1 || true; } > %t.p8
// RUN: { %kairo %s --type-check-only 2>&1 --cmax-errors=5 || true; } > %t.d
// RUN: diff %t.one %t.p1
// RUN: diff %t.one %t.p2
// RUN: diff %t.one %t.p3
// RUN: diff %t.one %t.p4
// RUN: diff %t.one %t.p5
// RUN: diff %t.one %t.p6
// RUN: diff %t.one %t.p7
// RUN: diff %t.one %t.p8
// RUN: diff %t.one %t.d
// RUN: %FileCheck %s < %t.one
// CHECK: part0.k:5:1: error [R010E]: "part0 stops here"
// CHECK: part1.k:5:1: error [R010E]: "part1 stops here"
// CHECK: part2.k:5:1: error [R010E]: "part2 stops here"
// CHECK: part3.k:5:1: error [R010E]: "part3 stops here"
// CHECK: part4.k:5:1: error [R010E]: "part4 stops here"
// CHECK: error [I957E]: too many errors emitted
// CHECK-NOT: R010E
