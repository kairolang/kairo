// A negative literal of 2^63 or more, stored in an i256 or i512, keeps its sign.
import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32) {
    if !(got == want) {
        println(f"FAIL {id}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn main() -> i32 {
    var a: i256 = -9223372036854775809
    var b: i256 = -18446744073709551615
    var c: i512 = -18446744073709551615
    var d: i512 = -9223372036854775808
    var e: i256 = -5
    ck(f"{a}", "-9223372036854775809", 1)
    ck(f"{b}", "-18446744073709551615", 2)
    ck(f"{c}", "-18446744073709551615", 3)
    ck(f"{d}", "-9223372036854775808", 4)
    ck(f"{e}", "-5", 5)
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
