// A function-local `static` slice literal keeps its backing array across
// calls: every later call reads the contents built by the first call, for
// each element, for a three-element slice and with a clobbering frame
// between the calls.

fn f(k: i32) -> i32 {
    static s: [i32;] = [k, k + 1, k + 2]
    var junk: [i32; 8] = [5, 5, 5, 5, 5, 5, 5, 5]
    return s[0] * 100 + s[1] * 10 + s[2] + junk[0] - 5
}

fn g() -> i32 {
    var z: [i32; 16] = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]
    return z[3]
}

fn main() -> i32 {
    var a = f(1)      // 1*100 + 2*10 + 3 = 123
    var b = g()
    var c = f(50)     // still 123
    var d = f(-4)     // still 123
    if a != 123 { return 1 }
    if c != 123 { return 2 }
    if d != 123 { return 3 }
    if b != 7 { return 4 }
    return 0
}

// --- lit wiring ---
// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo %s -O2 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
