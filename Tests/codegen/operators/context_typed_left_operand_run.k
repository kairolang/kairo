// A context-typed LEFT operand computes at the right operand's type
// (context_typed_left_operand.k pins the types; this pins the values the
// emitted C++ computes with them), and the operands are still evaluated left
// to right as written: typing the right one first moves nothing.
//
// Edge values: a literal at the bottom of its new type (`-128` as an i8), a
// u8 shift whose literal is the count's type, a u16 shift whose literal is
// the expected type rather than the count's, a literal past i32 against an
// i64, and a float literal that is an f32 (0.1 is not the same value at f32
// and f64, so the compare would fail if it were widened).

import std::io::println

enum Dir { North, South }
enum Opt { None, Some { v: i32 } }

var order: i32 = 0
fn nd() -> Dir { order = order * 10 + 7; return Dir::South; }
fn nb() -> u8 { order = order * 10 + 5; return 3; }

fn <T> pick(a: T, b: T, first: bool) -> T { if first { return a; } return b; }

fn main() -> i32 {
    var b: u8 = 3
    var s7: u8 = 7
    var s9: u8 = 9
    var m8: i8 = -128
    var i: i16 = -5
    var big: i64 = 1
    var f: f32 = 0.1
    var d = Dir::North

    var shl = 1 << s7                 // u8: 128
    var wide: u16 = 1 << s9           // u16 from the expected type: 512
    var sub = 255 - b                 // u8: 252
    var x = 0xFF ^ b                  // u8: 252
    var a = 0xF0 & 0x3Fu8             // u8: 48
    var neg = -1 * i                  // i16: 5
    var low = -128 == m8              // the bottom of i8 fits
    var past = 5000000000 - big       // i64: 4999999999
    var ff = 0.1 == f                 // compared as f32
    var dot = .North == d
    var dotne = .South != d
    var dotg = .South == pick(d, Dir::South, false)
    var o = Opt::Some { v: 3 }
    var none = .None == o
    var some = .None != o

    println(f"{shl} {wide} {sub} {x} {a} {neg} {low} {past} {ff}")
    println(f"{dot} {dotne} {dotg} {none} {some}")

    // Left to right: the right operand is typed first, never run first.
    var e1 = .North == nd()
    var e2 = 2 + nb() * nb()
    println(f"{e1} {e2} {order}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK: 128 512 252 252 48 5 true 4999999999 true
// CHECK-NEXT: true true true false true
// CHECK-NEXT: false 11 755
