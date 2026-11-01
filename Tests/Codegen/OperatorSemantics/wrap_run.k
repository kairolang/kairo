// OperatorSemantics: integer arithmetic wraps at the node's type, two's
// complement, with no C++ promotion observable, and a place is evaluated
// once. Each value below is UB, or a different value, as plain C++.

import std::io::*

struct Node { var count: i32 }

/// Bumps the counter it is given: proves its place expression ran once.
fn next(n: *i32) -> usize { (*n) += 1; return 0 }

fn main() -> i32 {
    var mx: i32 = 2147483647
    var p: u16 = 65535
    var m: i8 = -128
    var neg1: i8 = -1
    var minv: i32 = -2147483647 - 1
    var z: u8 = 0
    var c33: i32 = 33           // a runtime count: a constant one this large is an error
    var c9: i32 = 9
    var one8: u8 = 1
    println(f"add {mx + 1}")                 // ADD: add -2147483648
    println(f"mul {p * p}")                  // MUL: mul 1
    println(f"div {m / neg1}")               // DIV: div -128
    println(f"rem {minv % -1}")              // REM: rem 0
    println(f"shl {1i32 << c33} {one8 << c9} {one8 << c33}")   // SHL: shl 2 0 2
    println(f"shr {-8i32 >> c33} {m >> c9}")                   // SHR: shr -4 -1
    println(f"not {~z}")                     // NOT: not 255
    println(f"neg {-minv}")                  // NEG: neg -2147483648

    var node = Node { count: 2147483647 }
    node.count++
    var calls: i32 = 0
    var arr: [i32; 2] = [2147483647, 0]
    arr[next(&calls)] += 1
    var i: i32 = 2147483647
    var old = i++
    println(f"place {node.count} {arr[0]} {calls}")   // PLACE: place -2147483648 -2147483648 1
    println(f"post {old} {i}")                         // POST: post 2147483647 -2147483648

    var sum: i64 = 0
    for k in 0..10 { sum += k as i64 }
    for k in 250u8..=255u8 { sum += k as i64 }      // ..= to MAX: no wrap, no infinite loop
    println(f"loops {sum}")                            // LOOPS: loops 1560
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefixes=ADD,MUL,DIV,REM,SHL,SHR,NOT,NEG,PLACE,POST,LOOPS
