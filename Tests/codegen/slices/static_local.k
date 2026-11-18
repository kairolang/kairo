// A slice literal initializing a function-local `static` gets a `static`
// backing array, built once with it. The backing was a plain local of the
// first call's frame, so a later call read the static slice through a dead
// frame: here `f(50)` returned the slot's new contents (51), not the 2 the
// first call stored. Found checking the lifetimes of slice backings.

fn f(k: i32) -> i32 {
    static s: [i32;] = [k, k + 1]
    var junk: [i32; 8] = [9, 9, 9, 9, 9, 9, 9, 9]
    return s[1] + junk[0] - 9
}

fn g() -> i32 {
    var z: [i32; 16] = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]
    return z[3]
}

fn main() -> i32 {
    var a = f(1)
    var b = g()
    var c = f(50)
    return a * 10 + c + b - 7         // 2 * 10 + 2 == 22
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: static signed int __kairo_tmp{{[0-9]+}}[2] = {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 22
