// `x as U?` from a `T?` that is not proven non-null converts the value and
// keeps null: each rung a `T as U?` takes (a numeric conversion, a member
// `op as`, the library's `op as` to string, a converting constructor, a
// closed enum, a checked downcast) runs on the value, and null stays null.
// An operand that is no place is evaluated once.

import std::io

class Temp {
    var v: i32
    fn op as(self) -> i64 { return (self.v as i64) * 10 }
}

class Box {
    var v: i32
    fn Box(self, v: i32) { self.v = v }
}

enum Color derives u8 { Red = 1, Green = 2 }

class Animal { virtual fn kind(const self) -> i32 { return 0 } }
class Dog derives Animal { pub var bones: i32 = 7 }

var calls = 0

fn pass(x: i32?) -> i32? {
    calls += 1
    return x
}

fn show(x: i32?) -> string = x as string? ?? "none"

fn main() -> i32 {
    var a: i32? = 42
    var z: i32? = null
    io::println(f"string {show(a)} {show(z)}")

    var w: i64? = 300
    var wn: i64? = null
    var b? = w as u8?
    var bn? = wn as u8?
    io::println(f"narrow {b ?? 0} {bn?}")

    if w? {
        var wp? = w as i32?
        io::println(f"proven {wp ?? 0}")
    }

    var f: f64? = 2.75
    var fi? = f as i32?
    io::println(f"float {fi ?? -1}")

    var t: Temp? = Temp{v: 4}
    var tn: Temp? = null
    var ti? = t as i64?
    var tni? = tn as i64?
    io::println(f"op-as {ti ?? -1} {tni?}")

    var ba? = a as Box?
    var bz? = z as Box?
    var bv = if ba? => ba.v else => -1
    io::println(f"ctor {bv} {bz?}")

    var u: u8? = 2
    var un: u8? = null
    var e? = u as Color?
    var en? = un as Color?
    io::println(f"enum {e == Color::Green} {en?}")

    var c? = pass(5) as string?
    var cn? = pass(null) as string?
    io::println(f"once {c ?? "none"} {cn?} {calls}")

    var dog = Dog()
    var pa: *Animal? = &dog
    var pn: *Animal? = null
    var *d? = pa as *Dog?
    var *dn? = pn as *Dog?
    var bones = if d? => d->bones else => -1
    io::println(f"downcast {bones} {dn?}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT
// OUT:      string 42 none
// OUT-NEXT: narrow 44 false
// OUT-NEXT: proven 300
// OUT-NEXT: float 2
// OUT-NEXT: op-as 40 false
// OUT-NEXT: ctor 42 false
// OUT-NEXT: enum true false
// OUT-NEXT: once 5 false 2
// OUT-NEXT: downcast 7 false
