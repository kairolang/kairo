// Clang errors in two TUs of one build: this file and bad_lib.k. TUs are
// compiled side by side (P216), so both are reported, each TU's own in
// source order and the TUs in graph order (the import first), whichever
// worker finished first. clang's own "N errors generated." line, which two
// workers once wrote into each other, is not printed at all.

ffi "c++" import "vargs.h"
import bad_lib::*

fn main() -> i32 {
    var w: Narrow<256>
    var f: Flag<2>
    return w.width() + f.get() + lib_bad()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: generated
// CHECK: bad_lib.k:5:12: error [C115E]: non-type template argument evaluates to 300, which cannot be narrowed to type 'unsigned char'
// CHECK-NEXT: bad_lib.k:6:12: error [C115E]: non-type template argument evaluates to 3, which cannot be narrowed to type 'bool'
// CHECK-NEXT: two_tu_errors.k:11:12: error [C115E]: non-type template argument evaluates to 256, which cannot be narrowed to type 'unsigned char'
// CHECK-NEXT: two_tu_errors.k:12:12: error [C115E]: non-type template argument evaluates to 2, which cannot be narrowed to type 'bool'
// CHECK-NOT: generated
