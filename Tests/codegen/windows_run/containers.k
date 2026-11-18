// Vector, string and HashMap on the default library behave the same on
// Windows.

import std::io::println

fn main() -> i32 {
    var v: [string] = ["alpha", "beta", "gamma"]
    v.push("delta")
    println(f"size {v.size()}")
    var j = ""
    var first = true
    for *s in v {
        if !first { j += "-" }
        j += *s
        first = false
    }
    println(f"joined {j}")
    println(f"lens {v[0].size()} {v[1].size()} {v[2].size()} {v[3].size()}")

    var m: {string: i32}
    m["one"] = 1
    m["two"] = 2
    m["three"] = 3
    var total = 0
    for (k, x) in m { total += x }
    println(f"map {m.size()} two={m["two"]}")
    println(f"total {total}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: wine, sysroot-x86_64-windows-gnu
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s --target=x86_64-windows-gnu -o %t.exe --cache-dir %t.d
// RUN: %wine %t.exe | %FileCheck %s --match-full-lines
// CHECK: size 4
// CHECK-NEXT: joined alpha-beta-gamma-delta
// CHECK-NEXT: lens 5 4 5 5
// CHECK-NEXT: map 3 two=2
// CHECK-NEXT: total 6
