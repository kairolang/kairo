// OperatorSemantics: Kairo evaluates left to right -- a binary operator's
// operands, a call's receiver then its arguments, a subscript's base then
// its index, an assignment's place before its value, an initializer's
// fields as written. C++ leaves each unsequenced (or, for `=`, right first).

import std::io::*

var log: [u8; 16]
var n: usize = 0

fn note(c: u8, v: i32) -> i32 { log[n] = c; n += 1; return v }
fn idx(c: u8) -> usize { log[n] = c; n += 1; return 1 }
fn h(a: i32, b: i32) -> i32 { return a - b }

struct Pair { var a: i32; var b: i32 }

class Acc {
    pub var t: i32
    fn Acc(self) { self.t = 0 }
    fn add(self, v: i32) -> i32 { self.t += v; return self.t }
}

fn acc(a: *Acc) -> *Acc { log[n] = 114; n += 1; return a }   // 'r'

fn show(label: string) {
    var s = ""
    for var i: usize = 0; i < n; ++i { s = f"{s}{log[i] as char}" }
    println(f"{label} {s}")
    n = 0
}

fn main() -> i32 {
    var r = note(102, 5) - note(103, 3)          // 'f' 'g'
    show("sub")                                  // SUB: sub fg
    var c = h(note(102, 1), note(103, 2))
    show("call")                                 // CALL: call fg
    var arr: [i32; 2] = [0, 0]
    arr[idx(112)] = note(118, 7)                 // 'p' 'v'
    show("assign")                               // ASSIGN: assign pv
    var p = Pair { b: note(98, 2), a: note(97, 1) }
    show("init")                                 // INIT: init ba
    var a = Acc()
    var t = acc(&a)->add(note(97, 4))
    show("recv")                                 // RECV: recv ra
    return r + c + arr[1] + p.a + t - 13         // 2 + -1 + 7 + 1 + 4 - 13 == 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=SUB,CALL,ASSIGN,INIT,RECV
