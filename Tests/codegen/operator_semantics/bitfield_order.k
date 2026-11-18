// OperatorSemantics: `place = value` on an imported bit-field evaluates the
// place first, as any assignment does. No reference binds a bit-field, so
// SequenceLowering binds the object it is reached through and steps to the
// field again from that.

import std::io::*
ffi "c" import "bitfield.h"

var log: i32 = 0

fn at(p: *Bits) -> *Bits { log = log * 10 + 1; return p }
fn three() -> u32 { log = log * 10 + 2; return 3 }

fn main() -> i32 {
    var b: Bits
    b.u = 0
    unsafe { at(&b)->u = three() }
    println(f"{log} {b.u}")                         // OUT: 12 3
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
