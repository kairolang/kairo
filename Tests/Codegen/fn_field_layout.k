// A struct holding an `fn(i32) -> i32` (a 24-byte function value) and an
// `unsafe fn(i32) -> i32` (a raw 8-byte pointer) is 32 bytes: Sema's
// `sizeof` agrees with the C++ layout, so the `eval if` takes the
// matching branch and the program exits 0; the check also holds at
// alignment 8.

struct S {
    var a: fn(i32) -> i32
    var b: unsafe fn(i32) -> i32
}

fn zero() -> i32 { return 0 }
fn one() -> i32 { return 1 }

fn main() -> i32 {
    eval if sizeof S == 32 {
        eval if alignof S == 8 {
            return zero()
        }
    }
    return one()
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
// RUN: rm -rf %t.d2 %t2.exe
// RUN: %kairo %s -O2 -o %t2.exe --cache-dir %t.d2
// RUN: %t2.exe; test $? -eq 0
