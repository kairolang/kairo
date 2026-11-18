// The bound of an `eval for` is the only use of the imported `limit` here.
// The bounds of a lowered `eval for` are children of the loop like any
// other, so the emit plan sees the use and declares `limit` in this
// file's C++. A plan that skips the bounds emits a call of a function the
// translation unit never declares.
import lib::limit

fn sum() -> i32 {
    var s = 0
    eval for i in 0..limit() {
        s += i
    }

    return s
}

fn main() -> i32 {
    if sum() != 6 {
        return 1
    }

    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
