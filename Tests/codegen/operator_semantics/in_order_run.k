// OperatorSemantics: `x in xs` through a user `op in` evaluates x, then xs,
// as written. OperatorLowering makes it `xs.op_in(x)` -- the receiver is the
// source's right operand, and C++ evaluates a receiver before the arguments
// -- so the call records it (CallExpr::recv_last) and SequenceLowering binds
// x first.

import std::io::*

var log: [u8; 8]
var n: usize = 0

struct Bag {
    var v: i32
    fn op in(self, k: i32) -> bool { return self.v == k }
}

fn key(c: u8, v: i32) -> i32 { log[n] = c; n += 1; return v }
fn bag(c: u8, v: i32) -> Bag { log[n] = c; n += 1; return Bag { v: v } }

var g: i32 = 3
fn bump() -> Bag { g = 4; return Bag { v: 4 } }

fn main() -> i32 {
    var hit = key(120, 2) in bag(98, 2)              // 'x' 'b'
    var s = ""
    for var i: usize = 0; i < n; ++i { s = f"{s}{log[i] as char}" }
    println(f"in {s} {hit}")                         // IN: in xb true
    // x reads state the receiver's call changes: read first.
    var miss = g in bump()
    println(f"read {miss}")                          // READ: read false
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=IN,READ
