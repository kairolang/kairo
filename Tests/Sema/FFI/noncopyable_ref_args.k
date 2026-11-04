// SI1: a call that returns an imported `T&` passed to a `T&` parameter is
// passed on, not snapshotted by value (the evaluation-order temp was an `auto`
// copy of a non-copyable record).
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5

ffi "c++" import "Inputs/si1_noncopy.h"

fn main() -> i32 {
    return take_two(getd(), getd(), 3)
}
