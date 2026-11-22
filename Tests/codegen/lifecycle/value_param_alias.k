// A by-value parameter is the callee's own value (functions.mdx,
// Parameters): a write through a pointer to the caller's object, made while
// the call runs, does not reach it. A callee that moves its parameter on
// takes the caller's storage only when no pointer to that storage exists:
// a local whose address is taken anywhere in its function is passed as an
// object of the call's own, as is a value moved out of a field.
import std::io::println

class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) { self.id = 0 }
}

var none: R  = R(0)
var seen: *R = &none

fn through_param(p: R, q: *R) -> i32 {
    *q = R(70)
    var x = p
    return x.id
}

fn through_field(p: R, q: *R) -> i32 {
    q->id = 71
    var x = p
    return x.id
}

fn through_global(p: R) -> i32 {
    seen->id = 72
    var x = p
    return x.id
}

struct Box { var r: R }

fn through_owner(p: R, b: *Box) -> i32 {
    b->r = R(73)
    var x = p
    return x.id
}

fn main() -> i32 {
    {
        var a = R(1)
        var pa = &a
        println(f"param {through_param(a, pa)}")
    }
    {
        var b = R(2)
        var pb = &b
        println(f"field {through_field(b, pb)}")
    }
    {
        var c = R(3)
        seen = &c
        println(f"global {through_global(c)}")
    }
    {
        var d = Box { r: R(4) }
        println(f"owner {through_owner(d.r, &d)}")
    }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.o2.d
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// CHECK:      param 1
// CHECK-NEXT: field 2
// CHECK-NEXT: global 3
// CHECK-NEXT: owner 4
