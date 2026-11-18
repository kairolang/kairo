// A value argument the parameter cannot hold. Kairo keys the instance on
// the integer alone and does not range-check it against the C++ parameter
// type, so the fill declines it (no exact clang argument exists) and clang
// reports it when the emitted C++ is compiled -- at the Kairo use, with
// clang's own wording. Pinned so a later Sema-side check is a visible
// change, not a silent one.

ffi "c++" import "vargs.h"

fn main() -> i32 {
    var w: Narrow<256>
    var f: Flag<2>
    var b: Buf<i32, -1>
    return w.width() + f.get() + (b.cap() as i32)
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK: out_of_range.k:11:12: error [C115E]: non-type template argument evaluates to 256, which cannot be narrowed to type 'unsigned char'
// CHECK: out_of_range.k:12:12: error [C115E]: non-type template argument evaluates to 2, which cannot be narrowed to type 'bool'
// CHECK: out_of_range.k:13:18: error [C115E]: non-type template argument evaluates to -1, which cannot be narrowed to type 'unsigned int'
